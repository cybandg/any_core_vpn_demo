import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class VpnEnvironmentException implements Exception {
  final String message;

  const VpnEnvironmentException(this.message);

  @override
  String toString() => message;
}

class MacosCoresNotInstalledException implements Exception {
  final String detail;

  const MacosCoresNotInstalledException(this.detail);

  @override
  String toString() =>
      'macOS cores are not installed or damaged.\n'
      'Fix: run "flutter pub run any_core_vpn:setup_macos_cores" in the plugin '
      'project, then rebuild the app (flutter clean if the bundled copy is '
      'stale).\n'
      'Note: a sandboxed app sees a DIFFERENT home directory '
      '(~/Library/Containers/<id>/Data), so the runtime copy must be synced '
      'into the container as well - setup_macos_cores does this '
      'automatically.\n'
      'Diagnostics:\n$detail';
}

class MacosCoreFiles {
  final String root;

  /// Human-readable origin of the located copy (for logging).
  final String origin;

  const MacosCoreFiles(this.root, {this.origin = ''});

  String get singbox => '$root/sing-box';

  String get xray => '$root/xray';

  String get helper => '$root/helper';

  String get geoip => '$root/geoip.dat';

  String get geosite => '$root/geosite.dat';
}

class MacosEnvironmentGuard {
  const MacosEnvironmentGuard();

  Future<void> assertClean() async {
    final route = await Process.run('/sbin/route', ['-n', 'get', 'default']);

    final match = RegExp(
      r'interface:\s*(\S+)',
    ).firstMatch(route.stdout.toString());

    if (match != null && match.group(1)!.startsWith('utun')) {
      throw VpnEnvironmentException(
        'Another VPN is already active (interface ${match.group(1)}). '
        'Disconnect it and try again.',
      );
    }

    final proxy = await Process.run('/usr/sbin/scutil', ['--proxy']);
    final output = proxy.stdout.toString();

    for (final key in [
      'HTTPEnable : 1',
      'HTTPSEnable : 1',
      'SOCKSEnable : 1',
      'ProxyAutoConfigEnable : 1',
    ]) {
      if (output.contains(key)) {
        throw const VpnEnvironmentException(
          'A system proxy is already enabled. Disable it and try again.',
        );
      }
    }
  }
}

/// One candidate location + why it is a candidate.
class _Candidate {
  final String path;
  final String origin;

  const _Candidate(this.path, this.origin);
}

class MacosCoresLocator {
  final String? directory;

  const MacosCoresLocator({this.directory});

  /// Finds and verifies the cores directory.
  ///
  /// Candidate order:
  ///   1. explicit [directory]
  ///   2. $VPN_CORES_DIR
  ///   3. resource bundles embedded in the running .app
  ///      (any *.bundle containing manifest.json - covers CocoaPods
  ///       "any_core_vpn_cores.bundle" and SwiftPM
  ///       "any_core_vpn_any_core_vpn.bundle" alike)
  ///   4. runtime copy under the CURRENT $HOME
  ///      (inside App Sandbox this is ~/Library/Containers/<id>/Data/...)
  ///   5. runtime copy under the REAL user home (unsandboxed path)
  Future<MacosCoreFiles> locate() async {
    if (!Platform.isMacOS || Abi.current() != Abi.macosArm64) {
      throw UnsupportedError(
        'This backend requires native macOS ARM64, without Rosetta.',
      );
    }

    final problems = <String>[];

    for (final candidate in _candidates()) {
      try {
        return await _verify(candidate);
      } catch (error) {
        problems.add('  [${candidate.origin}] ${candidate.path} -> $error');
      }
    }

    final header = StringBuffer()
      ..writeln('  environment:')
      ..writeln(
        '    HOME                       : ${Platform.environment['HOME']}',
      )
      ..writeln(
        '    APP_SANDBOX_CONTAINER_ID   : '
        '${Platform.environment['APP_SANDBOX_CONTAINER_ID'] ?? '-'}',
      )
      ..writeln(
        '    executable                 : ${Platform.resolvedExecutable}',
      )
      ..writeln('  candidates checked:');

    throw MacosCoresNotInstalledException('$header${problems.join('\n')}');
  }

  // ---------- sandbox helpers ----------

  /// True when the process runs inside an App Sandbox container.
  static bool get _isSandboxed {
    final id = Platform.environment['APP_SANDBOX_CONTAINER_ID'];
    if (id != null && id.isNotEmpty) return true;
    final home = Platform.environment['HOME'] ?? '';
    return home.contains('/Library/Containers/');
  }

  /// Real user home. Inside a sandbox HOME is
  /// /Users/<u>/Library/Containers/<id>/Data -> /Users/<u>.
  static String? get _realHome {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final idx = home.indexOf('/Library/Containers/');
    if (idx == -1) return home; // not sandboxed
    return home.substring(0, idx);
  }

  static String _runtimeCores(String home) =>
      '$home/Library/Application Support/any_core_vpn/cores';

  // ---------- candidates ----------

  /// Only bundles that belong to this plugin are scanned - other plugins'
  /// bundles (shared_preferences, flutter_secure_storage, ...) can never
  /// contain our cores and only add noise to the diagnostics.
  static const pluginBundlePrefix = 'any_core_vpn';

  List<_Candidate> _candidates() {
    final out = <_Candidate>[];

    void add(String? path, String origin) {
      if (path == null || path.isEmpty) return;
      final normalized = p.normalize(path);
      if (out.any((c) => c.path == normalized)) return;
      out.add(_Candidate(normalized, origin));
    }

    add(directory, 'explicit');
    add(Platform.environment['VPN_CORES_DIR'], 'env:VPN_CORES_DIR');

    // Bundles embedded in the running .app.
    // <App>.app/Contents  (resolvedExecutable = .../Contents/MacOS/<app>)
    final contents = File(Platform.resolvedExecutable).parent.parent;
    for (final bundle in _scanBundles(contents.path)) {
      final payloads = _bundlePayloadRoots(bundle);
      for (final payload in payloads) {
        add(payload, 'app-bundle');
      }
      if (payloads.isEmpty) {
        // plugin bundle exists but holds no cores - keep it for diagnostics
        add(bundle, 'app-bundle:empty');
      }
    }

    // Runtime copy in the CURRENT home (container-aware).
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      add(_runtimeCores(home), _isSandboxed ? 'runtime:sandbox' : 'runtime');
    }

    // Runtime copy in the REAL home (differs from HOME when sandboxed).
    final realHome = _realHome;
    if (realHome != null) {
      add(_runtimeCores(realHome), 'runtime:real-home');
    }

    return out;
  }

  /// All *.bundle directories of THIS plugin under the app's Contents dir.
  /// Matches any naming: CocoaPods ("any_core_vpn_cores.bundle"), SwiftPM
  /// ("any_core_vpn_any_core_vpn.bundle"), etc.
  static List<String> _scanBundles(String contentsPath) {
    const maxDepth = 6;
    const maxFound = 8;
    final found = <String>[];

    void walk(Directory dir, int depth) {
      if (depth > maxDepth || found.length >= maxFound) return;

      final List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }

      for (final entity in entries) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);

        if (name.endsWith('.bundle')) {
          if (name.startsWith(pluginBundlePrefix)) found.add(entity.path);
          continue; // never descend into bundles here
        }
        if (name == 'Modules' || name.startsWith('.')) continue;

        walk(entity, depth + 1);
      }
    }

    walk(Directory(contentsPath), 0);
    return found;
  }

  /// Directories inside a .bundle that directly contain manifest.json.
  /// Covers <bundle>/cores (SwiftPM .copy), <bundle>/Contents/Resources and
  /// the bundle root itself.
  static List<String> _bundlePayloadRoots(String bundlePath) {
    final roots = <String>[];
    final root = Directory(bundlePath);
    if (!root.existsSync()) return roots;

    void walk(Directory dir, int depth) {
      if (depth > 4 || roots.length >= 3) return;
      if (File('${dir.path}/manifest.json').existsSync()) {
        roots.add(dir.path);
        return;
      }
      try {
        for (final e in dir.listSync(followLinks: false)) {
          if (e is Directory) walk(e, depth + 1);
        }
      } catch (_) {}
    }

    walk(root, 0);
    return roots;
  }
  // ---------- verification ----------

  Future<MacosCoreFiles> _verify(_Candidate candidate) async {
    final root = candidate.path;
    final manifestFile = File('$root/manifest.json');

    if (!await manifestFile.exists()) {
      throw StateError(Directory(root).existsSync()
          ? 'manifest.json missing'
          : 'directory does not exist');
    }

    final Map<String, dynamic> manifest;
    try {
      manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      throw StateError('manifest.json is not valid JSON: $e');
    }

    final rawFiles = manifest['files'];
    if (rawFiles is! Map) {
      throw StateError('manifest.json has no "files" map');
    }
    final files = rawFiles.cast<String, dynamic>();

    for (final entry in files.entries) {
      final expected = entry.value is String ? entry.value as String : '';
      final file = File('$root/${entry.key}');

      if (!await file.exists()) {
        throw StateError('${entry.key} missing');
      }

      final hash = (await sha256.bind(file.openRead()).first).toString();

      if (hash != expected) {
        // size + mtime instantly reveal a stale copy (e.g. old sing-box left
        // in a sandbox container by a previous version).
        throw StateError(
          '${entry.key} checksum mismatch (expected ${_short(expected)}, '
          'got ${_short(hash)}) ${_fileMeta(file)}',
        );
      }
    }

    return MacosCoreFiles(root, origin: candidate.origin);
  }

  static String _fileMeta(File f) {
    try {
      final st = f.statSync();
      return '[size=${st.size}, mtime=${st.modified.toIso8601String()}]';
    } catch (_) {
      return '[stat failed]';
    }
  }

  static String _short(String hash) =>
      hash.length <= 12 ? hash : '${hash.substring(0, 12)}...';
}
