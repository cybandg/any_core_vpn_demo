#!/usr/bin/env dart

//
// setup_android_cores.dart
// Builds libXray.aar (XTLS/libXray + Xray-core) and libbox.aar (SagerNet/sing-box)
// and copies them into <plugin_root>/android/libs.
// Additionally installs prebuilt hev-socks5-tunnel native libraries from the
// official .aar release into <plugin_root>/android/src/main/jniLibs/<abi>/.
//
// Versions are read from setup_cores.json in the plugin root
// (keys: xrayVersion, singboxVersion, optional libxrayRef, androidHevVersion).
//
// Requirements: git, python3, Go 1.22+, JDK 17+, Android SDK + NDK, ANDROID_HOME.
// For hev-socks5-tunnel extraction: unzip OR bsdtar OR PowerShell (Windows).
//
// Usage:
//   dart run tool/android/setup_android_cores.dart
//   dart run tool/android/setup_android_cores.dart --xray-version 26.7.28 --singbox-version 1.14.0
//   dart run tool/android/setup_android_cores.dart --hev-version 2.18.0
//   dart run tool/android/setup_android_cores.dart --skip-hev
//   dart run tool/android/setup_android_cores.dart --optimize-size
//   dart run tool/android/setup_android_cores.dart \
//     --custom-singbox-build-flags "-platform android/arm64,android/arm" \
//     --custom-xray-build-flags "-tags=mytag"

import 'dart:convert';
import 'dart:io';

// ---------- logging ----------
void log(String m) => stdout.writeln('==> $m');
void note(String m) => stdout.writeln('    $m');
Never fail(String m) {
  stderr.writeln('ERROR: $m');
  exit(1);
}

/// ':' on POSIX, ';' on Windows. Never use Platform.pathSeparator for PATH
/// strings blindly - be explicit to avoid copy/paste corruption.
final String pathListSep = Platform.isWindows ? ';' : ':';
final String sep = Platform.isWindows ? '\\' : '/';

// ---------- resolved executables ----------
late Map<String, String> _childEnv;
late String gitExe;
late String goExe;
late String javaExe;
late String pythonExe;

// ---------- small utils ----------
String baseName(String path) =>
    path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;

String humanSize(int bytes) {
  const units = ['B', 'K', 'M', 'G', 'T'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final digits = (v < 10 && i > 0) ? 1 : 0;
  return '${v.toStringAsFixed(digits)}${units[i]}';
}

/// Splits a user-provided flag string on whitespace into argv elements.
List<String> splitFlags(String s) =>
    s.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();

/// Recursively searches for a file named [fileName] under [root].
File? findFirst(String root, String fileName, {int maxDepth = 1 << 30}) {
  final dir = Directory(root);
  if (!dir.existsSync()) return null;

  File? walk(Directory d, int depth) {
    if (depth > maxDepth) return null;
    final entries = d.listSync();
    for (final e in entries) {
      if (e is File && baseName(e.path) == fileName) return e;
    }
    for (final e in entries) {
      if (e is Directory) {
        if (baseName(e.path) == '.git') continue;
        final r = walk(e, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  return walk(dir, 1);
}

/// Recursively searches for files named [fileName] whose PARENT directory
/// name is one of [abiNames]. Returns map: abi -> file.
/// Used for .aar layout: jni/<abi>/lib*.so (also matches lib/<abi>/... ).
Map<String, File> findSoFilesByAbi(
  String root,
  String fileName,
  Set<String> abiNames,
) {
  final result = <String, File>{};
  final dir = Directory(root);
  if (!dir.existsSync()) return result;

  void walk(Directory d) {
    for (final e in d.listSync()) {
      if (e is File && baseName(e.path) == fileName) {
        final parent = baseName(e.parent.path);
        if (abiNames.contains(parent)) result.putIfAbsent(parent, () => e);
      } else if (e is Directory) {
        walk(e);
      }
    }
  }

  walk(dir);
  return result;
}

// ---------- sha256 via system tooling ----------
//
// The previous pure-Dart SHA-256 carried an INCOMPLETE round-constant table
// (46 of 64 entries) and crashed at the final report; hand-maintaining
// crypto constants is a liability. We delegate to the OS hasher instead:
// shasum (macOS), sha256sum (Linux), certutil (Windows).
String sha256OfFile(String path) {
  try {
    if (Platform.isWindows) {
      final r = Process.runSync('certutil', [
        '-hashfile',
        path,
        'SHA256',
      ], runInShell: true);
      if (r.exitCode == 0) {
        for (final l in (r.stdout as String).split(RegExp(r'\r?\n'))) {
          final t = l.trim();
          if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t)) return t.toLowerCase();
        }
      }
      return 'unavailable';
    }
    final exe = resolveCommand('shasum') ?? resolveCommand('sha256sum');
    if (exe == null) return 'unavailable';
    final args = baseName(exe) == 'shasum' ? ['-a', '256', path] : [path];
    final r = Process.runSync(exe, args);
    if (r.exitCode != 0) return 'unavailable';
    return (r.stdout as String)
        .trim()
        .split(RegExp(r'\s+'))
        .first
        .toLowerCase();
  } catch (_) {
    return 'unavailable';
  }
}

// ---------- command resolution ----------
String? resolveCommand(String cmd) {
  try {
    final finder = Platform.isWindows ? 'where' : 'which';
    final r = Process.runSync(finder, [cmd], runInShell: true);
    if (r.exitCode == 0) {
      final first = (r.stdout as String)
          .trim()
          .split(RegExp(r'\r?\n'))
          .first
          .trim();
      if (first.isNotEmpty) return first;
    }
  } catch (_) {}

  final pathVar = Platform.environment['PATH'] ?? '';
  final names = Platform.isWindows
      ? ['$cmd.exe', '$cmd.bat', '$cmd.cmd', cmd]
      : [cmd];
  for (final dir in pathVar.split(pathListSep)) {
    if (dir.isEmpty) continue;
    for (final n in names) {
      final f = File('$dir$sep$n');
      if (f.existsSync()) return f.path;
    }
  }

  if (!Platform.isWindows) {
    for (final dir in [
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
    ]) {
      final f = File('$dir$sep$cmd');
      if (f.existsSync()) return f.path;
    }
  }
  return null;
}

Never commandNotFound(String cmd) {
  stderr.writeln("ERROR: '$cmd' not found.");
  stderr.writeln('       PATH seen by Dart: ${Platform.environment['PATH']}');
  exit(1);
}

// ---------- process helpers ----------
String shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// Runs a command streaming stdout/stderr, returns exit code.
/// On POSIX executes through /bin/sh with an explicit `export PATH=...`,
/// so the modified PATH reaches the process AND all its descendants
/// (python -> subprocess -> gomobile).
Future<int> runStream(String exe, List<String> args, {String? cwd}) async {
  note('\$ $exe ${args.join(' ')}${cwd != null ? '  (in $cwd)' : ''}');
  final Process p;
  if (Platform.isWindows) {
    p = await Process.start(
      exe,
      args,
      workingDirectory: cwd,
      environment: _childEnv,
      mode: ProcessStartMode.inheritStdio,
      runInShell: true,
    );
  } else {
    final pathValue = _childEnv['PATH'] ?? Platform.environment['PATH'] ?? '';
    final script = 'export PATH=${shellQuote(pathValue)}; exec "\$0" "\$@"';
    p = await Process.start(
      '/bin/sh',
      ['-c', script, exe, ...args],
      workingDirectory: cwd,
      environment: _childEnv,
      mode: ProcessStartMode.inheritStdio,
    );
  }
  return p.exitCode;
}

Future<void> runOrDie(
  String exe,
  List<String> args, {
  String? cwd,
  String? error,
}) async {
  final code = await runStream(exe, args, cwd: cwd);
  if (code != 0) {
    fail(error ?? "'$exe ${args.join(' ')}' failed with exit code $code");
  }
}

String runCapture(String exe, List<String> args, {String? cwd}) {
  try {
    final r = Process.runSync(
      exe,
      args,
      workingDirectory: cwd,
      environment: _childEnv,
      runInShell: Platform.isWindows,
    );
    if (r.exitCode != 0) return '';
    return (r.stdout as String).trim();
  } catch (_) {
    return '';
  }
}

// ---------- HTTP download ----------

/// Downloads [url] to [destPath] following redirects (GitHub release
/// downloads redirect to a CDN). Writes to a .part file first, then
/// renames, so a broken download never poisons the cache.
Future<void> downloadToFile(String url, String destPath) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 30);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.followRedirects = true;
    req.maxRedirects = 10;
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      fail('HTTP ${resp.statusCode} while downloading $url');
    }
    final total = resp.contentLength;
    final tmp = File('$destPath.part');
    final sink = tmp.openWrite();
    var received = 0;
    var lastNoteAt = 0;
    try {
      await for (final chunk in resp) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && received - lastNoteAt >= 4 * 1024 * 1024) {
          lastNoteAt = received;
          note('  ... ${humanSize(received)} / ${humanSize(total)}');
        }
      }
    } finally {
      await sink.close();
    }
    if (received == 0) {
      if (tmp.existsSync()) tmp.deleteSync();
      fail('downloaded file is empty: $url');
    }
    final dest = File(destPath);
    if (dest.existsSync()) dest.deleteSync();
    tmp.renameSync(destPath);
    note('downloaded: ${humanSize(received)} -> $destPath');
  } finally {
    client.close(force: true);
  }
}

// ---------- zip extraction ----------

/// Extracts a zip archive (an .aar IS a zip) into [destDir].
/// Tries, in order: unzip, tar (bsdtar reads zip; macOS and Windows 10+
/// ship it), PowerShell Expand-Archive (Windows). GNU tar will fail on
/// zip - that is fine, the chain just moves on.
bool extractZip(String zipPath, String destDir) {
  final unzip = resolveCommand('unzip');
  if (unzip != null) {
    final r = Process.runSync(
      unzip,
      ['-q', '-o', zipPath, '-d', destDir],
      environment: _childEnv,
      runInShell: Platform.isWindows,
    );
    if (r.exitCode == 0) return true;
    note('unzip failed (exit ${r.exitCode}): ${(r.stderr as String).trim()}');
  }

  final tar = resolveCommand('tar');
  if (tar != null) {
    final r = Process.runSync(
      tar,
      ['-xf', zipPath, '-C', destDir],
      environment: _childEnv,
      runInShell: Platform.isWindows,
    );
    if (r.exitCode == 0) return true;
    note('tar failed (exit ${r.exitCode}), trying next extractor');
  }

  if (Platform.isWindows) {
    final ps = resolveCommand('powershell');
    if (ps != null) {
      final z = zipPath.replaceAll("'", "''");
      final d = destDir.replaceAll("'", "''");
      final r = Process.runSync(
        ps,
        [
          '-NoProfile',
          '-Command',
          "Expand-Archive -LiteralPath '$z' -DestinationPath '$d' -Force",
        ],
        environment: _childEnv,
        runInShell: true,
      );
      if (r.exitCode == 0) return true;
      note('Expand-Archive failed (exit ${r.exitCode})');
    }
  }

  return false;
}

// ---------- git helpers ----------
void gitFetch(String dir) {
  if (Directory('$dir$sep.git').existsSync()) {
    runCapture(gitExe, ['-C', dir, 'fetch', '--tags', '--prune', 'origin']);
  }
}

Future<void> cloneOrUpdate(String url, String dir, String ref) async {
  if (Directory('$dir$sep.git').existsSync()) {
    note('updating $dir ($ref)');
    gitFetch(dir);
  } else {
    note('cloning $url');
    await runOrDie(gitExe, ['clone', url, dir]);
    await runOrDie(gitExe, ['-C', dir, 'fetch', '--tags', '--prune', 'origin']);
  }
  await runOrDie(gitExe, [
    '-C',
    dir,
    'checkout',
    '-f',
    ref,
  ], error: "git checkout of '$ref' failed in $dir");
  await runOrDie(gitExe, ['-C', dir, 'clean', '-fd']);
  final desc = runCapture(gitExe, [
    '-C',
    dir,
    'describe',
    '--tags',
    '--always',
  ]);
  note('${baseName(dir)} -> ${desc.isEmpty ? ref : desc}');
}

bool tagExists(String dir, String ref) {
  final r = Process.runSync(
    gitExe,
    ['-C', dir, 'rev-parse', '-q', '--verify', 'refs/tags/$ref'],
    environment: _childEnv,
    runInShell: Platform.isWindows,
  );
  return r.exitCode == 0;
}

// ---------- go toolchain helpers ----------

/// Directories where `go install` places binaries: GOBIN (if set) + GOPATH/bin.
List<String> goInstallDirs() {
  final dirs = <String>[];
  final gobin = runCapture(goExe, ['env', 'GOBIN']);
  if (gobin.isNotEmpty) dirs.add(gobin);
  final gopath = runCapture(goExe, ['env', 'GOPATH']);
  if (gopath.isNotEmpty) dirs.add('$gopath${sep}bin');
  return dirs;
}

String? findGoBinary(String name) {
  final exeName = Platform.isWindows ? '$name.exe' : name;
  for (final d in goInstallDirs()) {
    final p = '$d$sep$exeName';
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// Verifies the binary exists AND is executable (owner x bit).
void verifyExecutable(String path, String what) {
  final f = File(path);
  if (!f.existsSync()) fail('$what not found at $path');
  if (!Platform.isWindows) {
    final mode = FileStat.statSync(path).mode;
    if ((mode & 0x49) == 0) {
      // 0x49 = owner/group/other execute bits (0111 octal)
      fail(
        '$what at $path is NOT executable (mode: ${(mode & 0x1ff).toRadixString(8)})',
      );
    }
    note('$what mode : ${(mode & 0x1ff).toRadixString(8)} (executable: yes)');
  }
}

/// Installs official gomobile/gobind and verifies them.
/// libXray's build/main.py calls bare `gomobile` via PATH, so the binary
/// MUST exist, be executable, and its dir MUST be in child PATH.
Future<void> ensureGomobileInstalled() async {
  log('Installing gomobile + gobind (golang.org/x/mobile)');
  await runOrDie(goExe, [
    'install',
    '-v',
    'golang.org/x/mobile/cmd/gomobile@latest',
  ], error: 'go install gomobile failed');
  await runOrDie(goExe, [
    'install',
    '-v',
    'golang.org/x/mobile/cmd/gobind@latest',
  ], error: 'go install gobind failed');

  final gomobile = findGoBinary('gomobile');
  if (gomobile == null) {
    note('GOPATH : ${runCapture(goExe, ['env', 'GOPATH'])}');
    note('GOBIN  : ${runCapture(goExe, ['env', 'GOBIN'])}');
    note('dirs   : ${goInstallDirs().join(', ')}');
    fail('gomobile was installed but not found in GOBIN/GOPATH/bin');
  }
  verifyExecutable(gomobile, 'gomobile');
  note('gomobile : $gomobile');
  final gobind = findGoBinary('gobind');
  note('gobind   : ${gobind ?? 'NOT FOUND'}');
}

// ---------- hev-socks5-tunnel installer ----------

/// ABI folders expected under <plugin_root>/android/src/main/jniLibs.
const List<String> _hevAbis = ['arm64-v8a', 'armeabi-v7a', 'x86', 'x86_64'];
const String _hevSoName = 'libhev-socks5-tunnel.so';

/// Downloads the official prebuilt hev-socks5-tunnel .aar for [version],
/// extracts libhev-socks5-tunnel.so for every ABI and installs them into
/// [jniLibsDir]/<abi>/. The .aar is cached in [workDir]/hev, so repeated
/// runs with the same version do not re-download.
/// Returns the list of installed .so paths.
Future<List<String>> installHevSocks5Tunnel({
  required String version,
  required String workDir,
  required String jniLibsDir,
}) async {
  // Release tags of heiher/hev-socks5-tunnel have NO 'v' prefix (e.g. 2.18.0),
  // but tolerate 'v2.18.0' in config/CLI by stripping it.
  final tag = version.replaceFirst(RegExp('^v'), '');
  log('Installing hev-socks5-tunnel $tag (prebuilt .aar)');

  final url =
      'https://github.com/heiher/hev-socks5-tunnel/releases/download/$tag/hev-socks5-tunnel.aar';

  final hevDir = '$workDir${sep}hev';
  Directory(hevDir).createSync(recursive: true);
  final aarPath = '$hevDir${sep}hev-socks5-tunnel-$tag.aar';

  final cached = File(aarPath);
  if (cached.existsSync() && cached.lengthSync() > 0) {
    note('reusing cached aar: $aarPath (${humanSize(cached.lengthSync())})');
  } else {
    note('downloading $url');
    await downloadToFile(url, aarPath);
  }

  final extractDir = '$hevDir${sep}aar-$tag';
  final extractDirObj = Directory(extractDir);
  if (extractDirObj.existsSync()) extractDirObj.deleteSync(recursive: true);
  extractDirObj.createSync(recursive: true);

  note('extracting aar -> $extractDir');
  if (!extractZip(aarPath, extractDir)) {
    fail(
      'cannot extract $aarPath: no working zip extractor found '
      '(install unzip, or use macOS/Windows where bsdtar/Expand-Archive exist)',
    );
  }

  final soByAbi = findSoFilesByAbi(extractDir, _hevSoName, _hevAbis.toSet());
  if (soByAbi.isEmpty) {
    fail(
      '$_hevSoName not found inside the aar for any ABI '
      '($extractDir). Upstream archive layout may have changed.',
    );
  }

  final installed = <String>[];
  for (final abi in _hevAbis) {
    final src = soByAbi[abi];
    if (src == null) {
      note('WARNING: aar contains no $_hevSoName for ABI $abi - skipped');
      continue;
    }
    final destDir = Directory('$jniLibsDir$sep$abi');
    destDir.createSync(recursive: true);
    final destPath = '${destDir.path}$sep$_hevSoName';
    src.copySync(destPath);
    note('installed: $destPath (${humanSize(File(destPath).lengthSync())})');
    installed.add(destPath);
  }

  if (installed.isEmpty) {
    fail('no $_hevSoName was installed into $jniLibsDir');
  }
  note(
    'hev-socks5-tunnel $tag: ${installed.length}/${_hevAbis.length} ABIs installed',
  );
  return installed;
}

// ---------- size-optimization source patches ----------
//
// Why patch at all: neither libXray nor sing-box exposes CLI knobs for
// everything we need. libXray's android builder hardcodes an UNSTRIPPED
// ldflags and '-target android' (all ABIs); sing-box hardcodes its build
// tags in cmd/internal/build_libbox/main.go (but DOES expose -platform).
// Patches are applied AFTER checkout (checkout -f / clean -fd resets them),
// are anchored on unique literals, and FAIL LOUDLY if upstream drifts.

/// libXray: prod-ready ldflags (-s -w), optional ABI restriction and
/// extra user flags appended as python list elements.
void patchLibxrayAndroidPy(
  String path,
  String target,
  String ldflags,
  List<String> extraArgs,
) {
  final f = File(path);
  if (!f.existsSync()) fail('libXray android builder not found: $path');
  var src = f.readAsStringSync();

  final targetRe = RegExp(r'("-target",[\r\n]+[ \t]*)("android")');
  if (!targetRe.hasMatch(src)) {
    fail(
      'patch anchor not found in android.py: "-target", "android"\n'
      '       Upstream libXray layout changed - update patchLibxrayAndroidPy().',
    );
  }
  src = src.replaceFirstMapped(targetRe, (m) => '${m.group(1)}"$target"');

  final ldRe = RegExp(r'([ \t]*)"-ldflags=[^"]*",?');
  if (!ldRe.hasMatch(src)) {
    fail(
      'patch anchor not found in android.py: "-ldflags=..."\n'
      '       Upstream libXray layout changed - update patchLibxrayAndroidPy().',
    );
  }
  src = src.replaceFirstMapped(ldRe, (m) {
    final indent = m.group(1) ?? '';
    final b = StringBuffer('"-ldflags=$ldflags",');
    for (final a in extraArgs) {
      b.write('\n$indent"${a.replaceAll('"', '\\"')}",');
    }
    return b.toString();
  });

  f.writeAsStringSync(src);
  note(
    'patched: ${baseName(path)} (target=$target, stripped ldflags, '
    '${extraArgs.length} extra arg(s))',
  );
}

/// sing-box: tags that only make sense on a SERVER (or are huge and
/// client-useless) are removed from build_libbox's tag lists.
// ---------- optimize preset: plan, patch, limitations ----------

/// Server-only / client-useless sing-box tags removed by --optimize-size.
/// NOTE: 'with_clash_api' is INTENTIONALLY ABSENT: this app polls the
/// clash-api endpoint for traffic stats, and removing the tag makes
/// sing-box refuse to start any box whose config contains a clash_api
/// section. Re-add it here only after migrating stats to libbox callbacks.
const List<String> _singboxDropTags = [
  'with_dhcp',
  'with_acme',
  'with_reality_server',
  'with_tailscale',
];

/// Human-readable consequence of each dropped tag (for the final banner).
const Map<String, String> _tagLimitation = {
  'with_clash_api':
      'clash_api / external_controller REST endpoint (HTTP traffic stats); '
      'use libbox traffic callbacks instead',
  'with_dhcp':
      '"dhcp://..." addresses and DHCP-derived interface/DNS configuration',
  'with_acme': 'automatic TLS certificate issuance (ACME); server-side feature',
  'with_reality_server':
      'Reality in SERVER mode; client-side Reality is unaffected',
  'with_tailscale':
      'Tailscale integration (tailscale outbound and the ts_omit_* stack)',
};

String _limitationText(String tag) =>
    _tagLimitation[tag] ?? 'feature guarded by build tag $tag';

/// Env-override-aware drop list. Single source of truth for BOTH the
/// source patch and the limitations banner, so they can never disagree.
List<String> effectiveDropTags() {
  final envTags = Platform.environment['SINGBOX_DROP_TAGS'];
  if (envTags != null) {
    return envTags.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).toList();
  }
  return List<String>.from(_singboxDropTags);
}

bool effectiveDropsTsOmit(List<String> tags) =>
    Platform.environment['SINGBOX_DROP_TAGS'] == null ||
    tags.contains('with_tailscale');

/// Removes drop-tags from build_libbox tag lists at TOKEN level.
/// Literals are removed TOGETHER WITH ONE adjacent comma so no ",," is
/// ever produced; leftover comma runs are then repaired to a fixpoint.
/// The result is parse-checked with gofmt; on ANY syntax error the patch
/// is REVERTED and the build continues with the full tag set, so an
/// upstream layout change can never ship a gutted or broken core.
void pruneSingboxTags(String path, List<String> dropTags, bool dropTsOmit) {
  final f = File(path);
  if (!f.existsSync()) fail('sing-box build_libbox not found: $path');
  final original = f.readAsStringSync();
  var src = original;
  var dropped = 0;

  String dropLiteral(String s, String tag) {
    const sep = '__TAG__';
    final variants = [
      '"$sep", ',
      '"$sep",\n',
      '"$sep",',
      ', "$sep"',
      '"$sep"',
    ].map((v) => v.replaceAll(sep, tag)).toList();
    for (final v in variants) {
      if (s.contains(v)) return s.replaceFirst(v, '');
    }
    return s.replaceFirst('"$tag"', ''); // pathological fallback
  }

  for (final t in dropTags) {
    var guard = 0;
    while (src.contains('"$t"') && guard++ < 50) {
      src = dropLiteral(src, t);
      dropped++;
    }
  }

  if (dropTsOmit) {
    final tsRe = RegExp(
      r'"ts_omit_[a-z0-9_]*", ?|, "ts_omit_[a-z0-9_]*"|"ts_omit_[a-z0-9_]*"',
    );
    dropped += tsRe.allMatches(src).length;
    src = src.replaceAll(tsRe, '');
  }

  // Comma repair to FIXPOINT (comma runs of any length, first/last element).
  var prev = '';
  while (prev != src) {
    prev = src;
    src = src
        .replaceAll(RegExp(r',\s*,+'), ',')
        .replaceAll(RegExp(r'\(\s*,'), '(')
        .replaceAll(RegExp(r'\[\s*,'), '[')
        .replaceAll(RegExp(r'\{\s*,'), '{')
        .replaceAll(RegExp(r',\s*\)'), ')')
        .replaceAll(RegExp(r',\s*\]'), ']')
        .replaceAll(RegExp(r',\s*\}'), '}');
  }

  f.writeAsStringSync(src);

  final gofmt = resolveCommand('gofmt');
  if (gofmt != null) {
    final r = Process.runSync(gofmt, [
      '-e',
      '-l',
      path,
    ], environment: _childEnv);
    final err = (r.stderr as String).trim();
    if (r.exitCode != 0 || err.isNotEmpty) {
      f.writeAsStringSync(original);
      note(
        'WARNING: pruned build_libbox failed gofmt parse check - prune REVERTED:',
      );
      for (final l in err.split('\n').take(5)) {
        note('    $l');
      }
      note(
        '    Continuing with the FULL tag set (ABI restriction still applies).',
      );
      return;
    }
  } else {
    note('WARNING: gofmt not found; pruned Go source NOT validated.');
  }

  note(
    'sing-box size prune: removed $dropped tag literal(s); '
    'drop-list: ${dropTags.isEmpty ? "(empty - pruning disabled)" : dropTags.join(", ")}'
    '${dropTsOmit ? " + all ts_omit_*" : ""}',
  );
  if (dropTags.isNotEmpty && dropped == 0) {
    note(
      'WARNING: none of the drop-tags found in this sing-box version; nothing pruned.',
    );
  }
}

// ---------- final report ----------
void box(String s) => stdout.writeln('  ! $s');

void printFinalReport({
  required bool optimize,
  required String libxrayDest,
  required String libboxDest,
  required String abis,
  required bool singboxPruned,
  required List<String> droppedTags,
  required bool droppedTsOmit,
}) {
  stdout.writeln('');
  stdout.writeln('=' * 78);

  if (!optimize) {
    stdout.writeln('  DEFAULT BUILD  (all ABIs, all sing-box features)');
    stdout.writeln('=' * 78);
    box('libXray.aar : ${humanSize(File(libxrayDest).lengthSync())}');
    box('libbox.aar  : ${humanSize(File(libboxDest).lengthSync())}');
    box('');
    box('Re-run with --optimize-size for the prod-size preset (2-3x smaller).');
    box('WHAT THE PRESET WILL COST YOU (full banner is printed after an');
    box('optimized build; short version):');
    box('  * ABI restricted to android/arm64: no Intel x86/x86_64 emulators');
    box('    (ARM translation only), no 32-bit armeabi-v7a devices');
    for (final t in _singboxDropTags) {
      box('  * sing-box loses: ${_limitationText(t)}');
    }
    box('  * clash_api is KEPT by default in this repo (see _singboxDropTags)');
    box('Client protocols stay intact: vless, vmess, trojan, shadowsocks,');
    box(
      'hysteria, tuic, wireguard, ssh, uTLS, ECH, gVisor, QUIC, client Reality.',
    );
  } else {
    stdout.writeln('  OPTIMIZE-SIZE PRESET APPLIED');
    stdout.writeln('=' * 78);
    box('libXray.aar : ${humanSize(File(libxrayDest).lengthSync())}');
    box('libbox.aar  : ${humanSize(File(libboxDest).lengthSync())}');
    box('ABIs        : $abis');
    box('');
    box('-------------------------------------------------------------');
    box('LIMITATIONS OF THIS OPTIMIZED BUILD (vs the default build):');
    box('-------------------------------------------------------------');
    box('1) ABI = $abis');
    if (abis == 'android/arm64') {
      box('   - Intel x86/x86_64 emulators: only via ARM translation (slow,');
      box('     sometimes flaky); prefer arm64 system images.');
      box('   - 32-bit armeabi-v7a devices are NOT supported by this build.');
    }
    box('2) sing-box features REMOVED by build tags:');
    if (!singboxPruned || (droppedTags.isEmpty && !droppedTsOmit)) {
      box('   (none in this run - pruning was disabled or reverted, see log)');
    } else {
      if (droppedTags.isEmpty) {
        box('   (drop-list was empty in this run)');
      }
      for (final t in droppedTags) {
        box('   - ${t.replaceFirst('with_', '')}: ${_limitationText(t)}');
      }
      if (droppedTsOmit) {
        box('   - ts_omit_*: the entire Tailscale helper stack');
      }
    }
    box('3) Behaviour on a missing feature: sing-box validates the WHOLE');
    box('   config at BOX START and fails with "feature not included in');
    box('   this build" without dialing. Loud failure is by design.');
    box('4) Still fully supported: vless, vmess, trojan, shadowsocks,');
    box('   hysteria, hysteria2, tuic, wireguard, ssh, uTLS, ECH, gVisor,');
    box('   QUIC and client-side Reality.');
    box('5) Stripping (-s -w) applies in BOTH modes (xray via this script,');
    box('   sing-box via upstream); native crash symbol names are lost in');
    box('   both - keep unstripped copies per release for tombstone analysis.');
    box('');
    box('Undo ONE limitation: remove its tag from _singboxDropTags, or run');
    box('with SINGBOX_DROP_TAGS="tag1 tag2" ("" disables pruning entirely).');
    box('Undo ALL: build without --optimize-size.');
    box('');
    box('GEO NOTE: geo databases are NOT compiled into the cores; sing-box');
    box('  downloads geoip/geosite (.srs rule-sets) at RUNTIME (>= 1.12 has');
    box('  no geo code at all), Xray reads geoip.dat/geosite.dat from APP');
    box('  assets. App-side geo payloads are trimmed in the app, not here.');
  }
  stdout.writeln('=' * 78);
}

const _usage = '''
setup_android_cores.dart
Builds libXray.aar (XTLS/libXray + Xray-core) and libbox.aar (SagerNet/sing-box)
and copies them into <plugin_root>/android/libs. ALWAYS produces prod-ready
(stripped) .aar files. Also downloads the prebuilt hev-socks5-tunnel .aar and
installs libhev-socks5-tunnel.so into <plugin_root>/android/src/main/jniLibs/<abi>/.

Options:
  --xray-version <ver>      Xray-core version/tag
  --singbox-version <ver>   sing-box version/tag
  --hev-version <ver>       hev-socks5-tunnel version (release tag, e.g. 2.18.0)
  --libxray-ref <ref>       libXray git ref (default: tag matching xray-version)
  --out-dir <path>          output dir for .aar files
  --work-dir <path>         cache dir for git checkouts and hev .aar downloads
  --config <path>           path to setup_cores.json
  --skip-mobile-init        skip 'gomobile init'
  --skip-hev                skip hev-socks5-tunnel download/install
  --optimize-size           prod-size preset: arm64-only ABIs + prune
                            server-side sing-box tags (xray is stripped
                            in every mode)
  --custom-xray-build-flags "<flags>"
                            extra args appended to libXray's gomobile bind
                            (whitespace-separated, e.g. "-tags=foo")
  --custom-singbox-build-flags "<flags>"
                            extra args appended to build_libbox
                            (e.g. "-platform android/arm64,android/arm";
                            a custom -platform overrides the preset)
  -h, --help                show this help
''';

Future<void> main(List<String> argv) async {
  final scriptDir = File.fromUri(
    Platform.script,
  ).parent; // <root>/tool/android
  final toolRoot = scriptDir.parent; // <root>/tool
  final pluginRoot = toolRoot.parent; // <root>

  var configFile = '${pluginRoot.path}${sep}setup_cores.json';
  var outDir = '${pluginRoot.path}${sep}android${sep}libs';
  final jniLibsDir =
      '${pluginRoot.path}${sep}android${sep}src${sep}main${sep}jniLibs';
  var workDir =
      Platform.environment['WORK_DIR'] ??
      '${toolRoot.path}${sep}.android-cores-cache';

  var xrayVersion = '';
  var singboxVersion = '';
  var libxrayRef = '';
  var hevVersion = '';
  var skipMobileInit = (Platform.environment['SKIP_MOBILE_INIT'] ?? '0') == '1';
  var skipHev = (Platform.environment['SKIP_HEV'] ?? '0') == '1';

  // ---------- size / custom-flag options ----------
  var optimizeSize = false;
  var customXrayFlagsRaw = '';
  var customSingboxFlagsRaw = '';

  // ---------- args ----------
  var i = 0;
  String next(String flag) {
    if (i + 1 >= argv.length) fail('$flag requires a value');
    return argv[++i];
  }

  while (i < argv.length) {
    final raw = argv[i];
    final eq = raw.indexOf('=');
    final nameRaw = eq >= 0 ? raw.substring(0, eq) : raw;
    final inlineValue = eq >= 0 ? raw.substring(eq + 1) : '';
    final name = nameRaw.replaceFirst(RegExp('^-+'), '');

    switch (name) {
      case 'xray-version':
        xrayVersion = inlineValue.isNotEmpty ? inlineValue : next(raw);
        break;
      case 'singbox-version':
        singboxVersion = inlineValue.isNotEmpty ? inlineValue : next(raw);
        break;
      case 'hev-version':
        hevVersion = inlineValue.isNotEmpty ? inlineValue : next(raw);
        break;
      case 'libxray-ref':
        libxrayRef = inlineValue.isNotEmpty ? inlineValue : next(raw);
        break;
      case 'out-dir':
        outDir = inlineValue.isNotEmpty ? inlineValue : next(raw);
        break;
      case 'work-dir':
        workDir = inlineValue.isNotEmpty ? inlineValue : next(raw);
        break;
      case 'config':
        configFile = inlineValue.isNotEmpty ? inlineValue : next(raw);
        break;
      case 'skip-mobile-init':
        skipMobileInit = inlineValue.isEmpty ? true : inlineValue == 'true';
        break;
      case 'skip-hev':
        skipHev = inlineValue.isEmpty ? true : inlineValue == 'true';
        break;
      case 'optimize-size':
        optimizeSize = inlineValue.isEmpty ? true : inlineValue == 'true';
        break;
      case 'custom-xray-build-flags':
        customXrayFlagsRaw = inlineValue.isNotEmpty ? inlineValue : next(raw);
        break;
      case 'custom-singbox-build-flags':
        customSingboxFlagsRaw = inlineValue.isNotEmpty
            ? inlineValue
            : next(raw);
        break;
      case 'h':
      case 'help':
        stdout.writeln(_usage);
        exit(0);
      default:
        fail('unknown argument: ${argv[i]}');
    }
    i++;
  }

  final customXrayArgs = splitFlags(customXrayFlagsRaw);
  final customSingboxArgs = splitFlags(customSingboxFlagsRaw);

  // ---------- config ----------
  String jsonGet(String key) {
    final f = File(configFile);
    if (!f.existsSync()) return '';
    try {
      final data = jsonDecode(f.readAsStringSync());
      if (data is Map && data[key] is String) return data[key] as String;
    } catch (e) {
      fail('cannot parse $configFile: $e');
    }
    return '';
  }

  if (xrayVersion.isEmpty) xrayVersion = jsonGet('xrayVersion');
  if (singboxVersion.isEmpty) singboxVersion = jsonGet('singboxVersion');
  if (libxrayRef.isEmpty) libxrayRef = jsonGet('libxrayRef');
  if (hevVersion.isEmpty) hevVersion = jsonGet('androidHevVersion');

  if (xrayVersion.isEmpty) {
    fail('xrayVersion is empty (checked $configFile and --xray-version)');
  }
  if (singboxVersion.isEmpty) {
    fail('singboxVersion is empty (checked $configFile and --singbox-version)');
  }

  final xrayTag = 'v${xrayVersion.replaceFirst(RegExp('^v'), '')}';
  final singboxTag = 'v${singboxVersion.replaceFirst(RegExp('^v'), '')}';
  var resolvedLibxrayRef = libxrayRef;

  // ---------- environment ----------
  _childEnv = Map<String, String>.from(Platform.environment);

  log('Checking build environment');
  gitExe = resolveCommand('git') ?? commandNotFound('git');
  goExe = resolveCommand('go') ?? commandNotFound('go');
  javaExe = resolveCommand('java') ?? commandNotFound('java');
  pythonExe =
      resolveCommand('python3') ??
      resolveCommand('python') ??
      commandNotFound('python3');

  note('git     : $gitExe');
  note('go      : ${runCapture(goExe, ['version'])}');
  note('python3 : ${runCapture(pythonExe, ['--version'])}');
  final javaVer = Process.runSync(
    javaExe,
    ['-version'],
    environment: _childEnv,
    runInShell: Platform.isWindows,
  ).stderr.toString().split('\n').first;
  note('java    : $javaVer');

  final androidHome =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'];
  if (androidHome == null || androidHome.isEmpty) {
    fail(
      'ANDROID_HOME is not set. Install Android SDK + NDK and export ANDROID_HOME.',
    );
  }
  note('ANDROID_HOME: $androidHome');
  final ndkOverride = Platform.environment['NDK'];
  if (ndkOverride != null && ndkOverride.isNotEmpty) {
    note('NDK (override): $ndkOverride');
  }

  // ---------- PATH for children: GOBIN/GOPATH-bin FIRST, then original ----------
  final goDirs = goInstallDirs();
  if (goDirs.isEmpty) fail("could not resolve 'go env GOPATH'/'go env GOBIN'");
  final oldPath = Platform.environment['PATH'] ?? '';
  final newPath = [...goDirs, oldPath].join(pathListSep);
  _childEnv['PATH'] = newPath;

  // sanity check: the resulting PATH must literally start with "<goDir>:" (POSIX)
  note('go bin dirs : ${goDirs.join(', ')}');
  note(
    'PATH head   : ${newPath.substring(0, newPath.length.clamp(0, 120))}...',
  );
  if (!Platform.isWindows && !newPath.startsWith('${goDirs.first}:')) {
    fail(
      'INTERNAL: constructed PATH does not start with "${goDirs.first}:" - '
      'got "${newPath.substring(0, newPath.length.clamp(0, 80))}"',
    );
  }

  Directory(workDir).createSync(recursive: true);
  Directory(outDir).createSync(recursive: true);
  note('work dir : $workDir');
  note('out dir  : $outDir');
  note('jniLibs  : $jniLibsDir');

  if (resolvedLibxrayRef.isEmpty) resolvedLibxrayRef = xrayTag;

  // =========================================================
  // 0) hev-socks5-tunnel (fast: download + extract, no toolchain needed)
  //    Runs FIRST so a broken download fails fast, before the long build.
  // =========================================================
  var hevInstalled = <String>[];
  if (skipHev) {
    log('Skipping hev-socks5-tunnel install (--skip-hev)');
  } else if (hevVersion.isEmpty) {
    note(
      'WARNING: androidHevVersion is empty (checked $configFile and '
      '--hev-version); skipping hev-socks5-tunnel install.',
    );
  } else {
    hevInstalled = await installHevSocks5Tunnel(
      version: hevVersion,
      workDir: workDir,
      jniLibsDir: jniLibsDir,
    );
  }

  // install gomobile BEFORE libXray build (build/main.py calls bare `gomobile`)
  await ensureGomobileInstalled();

  // ---- probe: verify children really see gomobile via PATH ----
  log('Probe: checking gomobile visibility in child processes');
  await runStream('/bin/sh', [
    '-c',
    'echo "\$PATH" | tr ":" "\\n" | head -n 3; '
        'command -v gomobile || { echo "gomobile NOT visible to child"; exit 1; }',
  ]);

  // =========================================================
  // 1) libXray.aar
  // =========================================================
  log('Building libXray.aar (Xray $xrayTag)');

  final libxrayDir = '$workDir${sep}libXray';
  final xrayDir = '$workDir${sep}Xray-core';

  if (!Directory('$libxrayDir$sep.git').existsSync()) {
    await runOrDie(gitExe, [
      'clone',
      'https://github.com/XTLS/libXray.git',
      libxrayDir,
    ]);
  }
  gitFetch(libxrayDir);

  if (!tagExists(libxrayDir, resolvedLibxrayRef)) {
    note(
      "WARNING: libXray has no tag '$resolvedLibxrayRef', falling back to 'main'.",
    );
    note(
      'WARNING: libXray main is only compatible with the LATEST Xray-core release;',
    );
    note(
      'WARNING: building it against an older Xray-core (e.g. $xrayTag) WILL fail.',
    );
    resolvedLibxrayRef = 'main';
  }

  await cloneOrUpdate(
    'https://github.com/XTLS/libXray.git',
    libxrayDir,
    resolvedLibxrayRef,
  );
  await cloneOrUpdate(
    'https://github.com/XTLS/Xray-core.git',
    xrayDir,
    xrayTag,
  );

  // Always prod-ready: -s -w strips symbols+DWARF. ABI restriction only in
  // optimize mode (default keeps emulator slices).
  final xrayTarget = optimizeSize ? 'android/arm64' : 'android';
  const xrayLdflags =
      '-s -w -checklinkname=0 -extldflags=-Wl,-z,max-page-size=16384';
  patchLibxrayAndroidPy(
    '$libxrayDir${sep}build${sep}app${sep}android.py',
    xrayTarget,
    xrayLdflags,
    customXrayArgs,
  );

  await runOrDie(
    pythonExe,
    ['build/main.py', 'android', 'local'],
    cwd: libxrayDir,
    error: 'libXray build (build/main.py android local) failed',
  );

  var libxrayAar = findFirst('$libxrayDir${sep}build', 'libXray.aar');
  libxrayAar ??= findFirst(libxrayDir, 'libXray.aar');
  if (libxrayAar == null) fail('libXray.aar was not produced by the build');

  final libxrayDest = '$outDir${sep}libXray.aar';
  libxrayAar.copySync(libxrayDest);
  note(
    'installed: $libxrayDest (${humanSize(File(libxrayDest).lengthSync())})',
  );

  // =========================================================
  // 2) libbox.aar
  // =========================================================
  log('Building libbox.aar (sing-box $singboxTag)');

  final singboxDir = '$workDir${sep}sing-box';
  await cloneOrUpdate(
    'https://github.com/SagerNet/sing-box.git',
    singboxDir,
    singboxTag,
  );

  log('Installing SagerNet gomobile fork');
  await runOrDie(goExe, [
    'install',
    '-v',
    'github.com/sagernet/gomobile/cmd/gomobile@latest',
  ], error: 'go install SagerNet gomobile failed');
  await runOrDie(goExe, [
    'install',
    '-v',
    'github.com/sagernet/gomobile/cmd/gobind@latest',
  ], error: 'go install SagerNet gobind failed');

  final gomobilePath = findGoBinary('gomobile');
  if (gomobilePath == null) {
    fail(
      'SagerNet gomobile installed but binary not found in ${goInstallDirs().join(', ')}',
    );
  }
  verifyExecutable(gomobilePath, 'gomobile (fork)');
  note('gomobile (SagerNet fork) : $gomobilePath');

  if (!skipMobileInit) {
    note(
      "running 'gomobile init' (one-time NDK toolchain setup, can take a few minutes)",
    );
    await runOrDie(gomobilePath, ['init'], error: 'gomobile init failed');
  } else {
    note('gomobile init skipped (--skip-mobile-init)');
  }

  // optimize preset: restrict ABIs via official -platform flag (if this
  // sing-box version has it) and prune server-side tags from build_libbox.
  var singboxPlatformArgs = <String>[];
  var singboxPruned = false;
  var abis = 'all (arm, arm64, 386, amd64)';
  var planTags = <String>[];
  var planTsOmit = false;
  if (optimizeSize) {
    planTags = effectiveDropTags();
    planTsOmit = effectiveDropsTsOmit(planTags);
    final libboxMainGo =
        '$singboxDir${sep}cmd${sep}internal${sep}build_libbox${sep}main.go';
    final mainSrc = File(libboxMainGo).readAsStringSync();
    if (mainSrc.contains('flag.StringVar(&platform')) {
      singboxPlatformArgs = ['-platform', 'android/arm64'];
      abis = 'android/arm64';
    } else {
      note(
        'WARNING: this sing-box version has no -platform flag in '
        'build_libbox; ABI restriction skipped (tags still pruned).',
      );
    }
    pruneSingboxTags(libboxMainGo, planTags, planTsOmit);
    singboxPruned = true;
  }

  await runOrDie(
    goExe,
    [
      'run',
      './cmd/internal/build_libbox',
      '-target',
      'android',
      ...singboxPlatformArgs,
      ...customSingboxArgs, // a custom -platform here overrides the preset
    ],
    cwd: singboxDir,
    error: 'build_libbox failed',
  );

  final libboxAar = findFirst(singboxDir, 'libbox.aar', maxDepth: 2);
  if (libboxAar == null) fail('libbox.aar was not produced by the build');

  final libboxDest = '$outDir${sep}libbox.aar';
  libboxAar.copySync(libboxDest);
  note('installed: $libboxDest (${humanSize(File(libboxDest).lengthSync())})');

  // =========================================================
  // Done
  // =========================================================
  log('Done');
  note('xray        : $xrayTag');
  note('libXray     : $resolvedLibxrayRef');
  note('sing-box    : $singboxTag');
  note(
    'hev-socks5  : ${skipHev ? 'SKIPPED' : (hevVersion.isEmpty ? 'NOT CONFIGURED' : hevVersion.replaceFirst(RegExp('^v'), ''))}'
    '${hevInstalled.isEmpty ? '' : ' (${hevInstalled.length} .so installed)'}',
  );
  note('libXray.aar : $libxrayDest');
  note('libbox.aar  : $libboxDest');
  for (final p in hevInstalled) {
    note('hev .so     : $p');
  }
  note('sha256:');
  for (final p in [libxrayDest, libboxDest, ...hevInstalled]) {
    note('    ${sha256OfFile(p)}  ${baseName(p)}');
  }

  printFinalReport(
    optimize: optimizeSize,
    libxrayDest: libxrayDest,
    libboxDest: libboxDest,
    abis: abis,
    singboxPruned: singboxPruned,
    droppedTags: planTags,
    droppedTsOmit: planTsOmit,
  );
}
