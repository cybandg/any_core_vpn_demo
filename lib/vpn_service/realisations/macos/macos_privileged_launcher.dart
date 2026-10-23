import 'dart:io';

import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'macos_cores.dart';

/// State of the one-time "password-free start" installation.
enum PasswordlessStatus {
  /// Nothing installed: every start goes through the osascript password dialog.
  notInstalled,

  /// Installed and the sudoers rule actually answers without a password.
  ready,

  /// Installed, but the pinned root-owned cores differ from the bundle ones
  /// (you updated the cores) — the wrapper would still run the OLD binaries.
  outdated,

  /// Files are there but `sudo -n` refuses: rule removed / sudoers broken.
  broken,
}

/// One-time installer + runtime broker for password-free supervisor launches.
///
/// WHY: `osascript ... with administrator privileges` has no "remember"
/// option and caches nothing, so every connect pops the password dialog.
/// The supported no-Xcode alternative is a pinned sudoers rule that allows
/// the user to run ONE root-owned wrapper without a password.
///
/// SECURITY: granting NOPASSWD on `helper` directly would be a local root
/// escalation — the session manifest lives in a user-writable directory and
/// names the binary that root executes. So sudoers only ever grants the
/// wrapper, and the wrapper refuses to run unless the manifest points at one
/// of the pinned, root-owned cores.
class MacosPrivilegedLauncher {
  MacosPrivilegedLauncher._();

  static final MacosPrivilegedLauncher instance = MacosPrivilegedLauncher._();

  static const String installDir = '/usr/local/libexec/any_core_vpn';
  static const String wrapper = '$installDir/sudo-helper';
  static const String sudoersFile = '/etc/sudoers.d/any_core_vpn';

  static const List<String> _pinnedNames = ['helper', 'xray', 'sing-box'];

  String pinnedPath(String name) => '$installDir/$name';

  /// Root-owned binary for [core], or null when nothing is pinned yet.
  String? pinnedBinaryFor(VpnCore core) {
    final path = pinnedPath(core == VpnCore.singbox ? 'sing-box' : 'xray');
    return File(path).existsSync() ? path : null;
  }

  /// Authoritative check: does `sudo -n` run our wrapper without a password?
  Future<bool> get isPasswordlessReady async {
    if (!Platform.isMacOS) return false;
    if (!File(wrapper).existsSync()) return false;
    try {
      final probe = await Process.run('/usr/bin/sudo', [
        '-n',
        wrapper,
        '--probe',
      ]);
      return probe.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<PasswordlessStatus> status(MacosCoreFiles files) async {
    if (!Platform.isMacOS) return PasswordlessStatus.notInstalled;

    final missing = _pinnedNames.where(
      (n) => !File(pinnedPath(n)).existsSync(),
    );
    if (missing.isNotEmpty) return PasswordlessStatus.notInstalled;

    if (!await isPasswordlessReady) return PasswordlessStatus.broken;

    // Cores updated in the bundle but not re-pinned => stale root binaries.
    for (final name in ['xray', 'sing-box', 'helper']) {
      final src = name == 'helper'
          ? files.helper
          : (name == 'xray' ? files.xray : files.singbox);
      if (!await _sameSha256(src, pinnedPath(name))) {
        return PasswordlessStatus.outdated;
      }
    }
    return PasswordlessStatus.ready;
  }

  Future<bool> _sameSha256(String a, String b) async {
    try {
      final fa = File(a), fb = File(b);
      if (!await fa.exists() || !await fb.exists()) return false;
      if (await fa.length() != await fb.length()) return false;
      final ha = await sha256.bind(fa.openRead()).first;
      final hb = await sha256.bind(fb.openRead()).first;
      return ha == hb;
    } catch (_) {
      return false;
    }
  }

  /// Launches the privileged supervisor. Password-free when installed,
  /// otherwise falls back to the osascript admin dialog.
  Future<Process> startSupervisor({
    required String sessionPath,
    required String fallbackAppleScript,
  }) async {
    if (await isPasswordlessReady) {
      return Process.start('/usr/bin/sudo', [
        '-n',
        wrapper,
        'run',
        sessionPath,
      ]);
    }
    return Process.start('/usr/bin/osascript', ['-e', fallbackAppleScript]);
  }

  /// ONE admin prompt: pins the cores + wrapper and installs the sudoers rule.
  /// Re-running it is safe (idempotent overwrite) — use it after updating cores.
  Future<void> install(MacosCoreFiles files) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('Password-free start is macOS-only.');
    }

    final user = _currentUserName();
    final script = _installScript(sourceRoot: files.root, user: user);

    // Run the installer from a 0700 temp dir: root executes it, so a
    // world-writable location would be a TOCTOU hole.
    final tmpDir = await Directory.systemTemp.createTemp(
      'any_core_vpn_install',
    );
    await Process.run('/bin/chmod', ['700', tmpDir.path]);
    final scriptFile = File(p.join(tmpDir.path, 'install.sh'));
    await scriptFile.writeAsString(script);
    await Process.run('/bin/chmod', ['600', scriptFile.path]);

    try {
      final result = await Process.run('/usr/bin/osascript', [
        '-e',
        'do shell script ${_appleScriptQuote('/bin/bash ${_shellQuote(scriptFile.path)}')} '
            'with administrator privileges',
      ]);

      if (result.exitCode != 0) {
        final err = (result.stderr.toString() + result.stdout.toString())
            .trim();
        if (err.contains('User canceled') || err.contains('-128')) {
          throw const VpnEnvironmentException(
            'Установка отменена: пароль администратора не введён.',
          );
        }
        throw StateError('Password-free install failed: $err');
      }
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }

    if (!await isPasswordlessReady) {
      throw StateError(
        'Installer finished but `sudo -n $wrapper --probe` still fails. '
        'Check $sudoersFile (visudo -c) and that /usr/bin/sudo is not wrapped '
        'by a third-party policy plugin.',
      );
    }
  }

  /// ONE admin prompt: removes the sudoers rule and the pinned binaries.
  Future<void> uninstall() async {
    final script =
        '''
set -eu
/bin/rm -f '${MacosPrivilegedLauncher.sudoersFile}'
/bin/rm -rf '${MacosPrivilegedLauncher.installDir}'
echo removed
''';

    final tmpDir = await Directory.systemTemp.createTemp(
      'any_core_vpn_uninstall',
    );
    await Process.run('/bin/chmod', ['700', tmpDir.path]);
    final scriptFile = File(p.join(tmpDir.path, 'uninstall.sh'));
    await scriptFile.writeAsString(script);
    await Process.run('/bin/chmod', ['600', scriptFile.path]);

    try {
      final result = await Process.run('/usr/bin/osascript', [
        '-e',
        'do shell script ${_appleScriptQuote('/bin/bash ${_shellQuote(scriptFile.path)}')} '
            'with administrator privileges',
      ]);
      if (result.exitCode != 0) {
        throw StateError(
          'Uninstall failed: ${(result.stderr.toString() + result.stdout.toString()).trim()}',
        );
      }
    } finally {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  String _currentUserName() {
    final env = Platform.environment['USER'];
    if (env != null && env.isNotEmpty) return env;
    final home = Platform.environment['HOME'] ?? '';
    final name = p.basename(home);
    if (name.isEmpty || name == '/') {
      throw StateError(
        'Cannot determine the current user name (USER/HOME unset)',
      );
    }
    return name;
  }

  /// The installer, executed ONCE as root. Writes:
  ///  - $installDir/{helper,xray,sing-box}  root:wheel 0755 (pinned cores)
  ///  - $installDir/sudo-helper             root:wheel 0755 (validating wrapper)
  ///  - /etc/sudoers.d/any_core_vpn         root:wheel 0440 (NOPASSWD rule)
  ///
  /// The sudoers rule intentionally specifies NO arguments: per sudoers(5)
  /// that means "any arguments", which avoids wildcard/whitespace escaping of
  /// session paths under "~/Library/Application Support/...".
  String _installScript({required String sourceRoot, required String user}) {
    return '''
set -eu

SRC=${_bashQuote(sourceRoot)}
DST=${_bashQuote(installDir)}
USER_NAME=${_bashQuote(user)}
SUDOERS=${_bashQuote(sudoersFile)}

/bin/mkdir -p "\$DST"
/usr/sbin/chown root:wheel "\$DST"
/bin/chmod 0755 "\$DST"

for f in helper xray sing-box; do
  if [ ! -f "\$SRC/\$f" ]; then
    echo "source core missing: \$SRC/\$f" >&2
    exit 4
  fi
  /bin/cp "\$SRC/\$f" "\$DST/\$f"
  /usr/sbin/chown root:wheel "\$DST/\$f"
  /bin/chmod 0755 "\$DST/\$f"
done

/bin/cat > "\$DST/sudo-helper" <<'WRAPPER_EOF'
#!/bin/bash
# Root-owned launcher wrapper for any_core_vpn.
#
# Granted via /etc/sudoers.d/any_core_vpn (NOPASSWD) so the user can start the
# VPN supervisor without re-entering the admin password on every connect.
#
# SECURITY: sudoers can pin the COMMAND but not what a user-writable session
# manifest asks root to execute. This wrapper closes that gap — it refuses to
# run unless the session's core binary is one of the pinned, root-owned cores.
set -euo pipefail

PINNED_DIR="/usr/local/libexec/any_core_vpn"

if [ "\${1:-}" = "--probe" ]; then
  echo "any_core_vpn sudo wrapper OK"
  exit 0
fi

if [ "\${1:-}" != "run" ] || [ -z "\${2:-}" ]; then
  echo "usage: sudo-helper run <session-dir>" >&2
  exit 2
fi

SESSION="\$2"
MANIFEST="\$SESSION/manifest.json"

if [ ! -d "\$SESSION" ] || [ ! -f "\$MANIFEST" ]; then
  echo "no session manifest at \$MANIFEST" >&2
  exit 2
fi

BIN="\$(/usr/bin/plutil -extract binary raw -o - "\$MANIFEST" 2>/dev/null || true)"
if [ -z "\$BIN" ]; then
  # plutil could not parse it: crude but dependency-free fallback.
  BIN="\$(/usr/bin/sed -n 's/.*"binary"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' "\$MANIFEST" | /usr/bin/head -n 1)"
fi

case "\$BIN" in
  "\$PINNED_DIR/xray"|"\$PINNED_DIR/sing-box") ;;
  *)
    echo "refusing to run: binary '\$BIN' is not a pinned core in \$PINNED_DIR" >&2
    exit 3
    ;;
esac

# sudo resets HOME to /var/root; the helper and the cores expect the user's one.
if [ -n "\${SUDO_USER:-}" ] && [ -d "/Users/\$SUDO_USER" ]; then
  export HOME="/Users/\$SUDO_USER"
fi

exec "\$PINNED_DIR/helper" run "\$SESSION"
WRAPPER_EOF

/usr/sbin/chown root:wheel "\$DST/sudo-helper"
/bin/chmod 0755 "\$DST/sudo-helper"

TMP="\$(/usr/bin/mktemp /tmp/any_core_vpn_sudoers.XXXXXX)"
/usr/bin/printf '%s\\n' "\$USER_NAME ALL=(root) NOPASSWD: \$DST/sudo-helper" > "\$TMP"
/usr/sbin/chown root:wheel "\$TMP"
/bin/chmod 0440 "\$TMP"

# Validate BEFORE installing: a broken file in /etc/sudoers.d can lock sudo out.
/usr/sbin/visudo -c -f "\$TMP"
/bin/mv "\$TMP" "\$SUDOERS"
/bin/chmod 0440 "\$SUDOERS"

echo "password-free start installed for \$USER_NAME"
''';
  }

  static String _bashQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  static String _appleScriptQuote(String value) =>
      '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
}
