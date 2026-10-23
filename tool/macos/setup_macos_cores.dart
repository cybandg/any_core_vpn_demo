#!/usr/bin/env dart

//
// setup_macos_cores.dart
// Downloads prebuilt sing-box and Xray-core binaries for macOS (arm64),
// verifies them against the sha256 digests published in the GitHub release,
// compiles the Swift supervisor (helper.swift) and installs everything into:
//   1) <plugin_root>/macos/cores                    (canonical install)
//   2) SwiftPM resources dir (auto-detected)        (so the cores are packed
//                                                    into the app bundle)
//   3) ~/Library/Application Support/any_core_vpn/cores  (runtime fallback)
//
// Versions: CLI args > setup_cores.json (plugin root) > built-in defaults.
//
// Requirements: macOS on Apple Silicon, tar, ditto, Xcode CLI tool (swiftc).
//
// Usage:
//   dart tool/macos/setup_macos_cores.dart
//   dart tool/macos/setup_macos_cores.dart --xray-version 26.7.28 --singbox-version 1.14.0

import 'dart:convert';
import 'dart:io';

import 'cores_common.dart';

// runtime copy directory name under ~/Library/Application Support/
const _runtimeDirName = 'any_core_vpn';

const _usage = '''
setup_macos_cores.dart - install macOS cores (sing-box / xray / helper)

Usage:
  dart tool/macos/setup_macos_cores.dart [options]

Versions (precedence: CLI > setup_cores.json > error):
  --singbox-version <ver>    sing-box version
  --xray-version <ver>       Xray-core version
  --config <path>            alternative setup_cores.json
                             (default: <plugin_root>/setup_cores.json,
                              keys: xrayVersion, singboxVersion)

Options:
  --cores-dir <path>         canonical install dir
                             (default: <plugin_root>/macos/cores)
  --runtime-dir <path>       runtime copy dir
                             (default: ~/Library/Application Support/any_core_vpn/cores)
  --skip-runtime-sync        do not create the runtime copy
  --skip-bundle-sync         do not copy cores into SwiftPM resources
  --skip-containers          do not sync into App Sandbox containers
  --skip-helper              do not compile helper.swift
  -h, --help                 show this help

Env:
  GITHUB_TOKEN=<token>       raise the GitHub API rate limit
  VPN_CORES_DIR=<path>       same as --cores-dir
''';

// ---------- github helpers ----------

Future<String> assetSha256(String repo, String tag, String asset) async {
  final data = await githubGetJson(
    'https://api.github.com/repos/$repo/releases/tags/$tag',
  );
  if (data is! Map || data['assets'] is! List) {
    fail('unexpected GitHub API response for $repo@$tag');
  }
  for (final a in data['assets'] as List) {
    if (a is Map && a['name'] == asset) {
      final digest = a['digest'];
      if (digest is String && digest.startsWith('sha256:')) {
        return digest.substring(7);
      }
      fail('no sha256 digest published for $asset ($repo@$tag)');
    }
  }
  fail('asset $asset not found in release $repo@$tag');
}

Future<void> downloadVerified(
  String asset,
  String url,
  String expected,
  File out,
) async {
  log('Downloading $asset ...');
  final actual = await downloadAndHash(url, out);
  if (actual != expected) {
    fail(
      'Checksum mismatch for $asset:\n'
      '    expected: $expected\n'
      '    actual  : $actual',
    );
  }
  note('sha256 OK: $actual');
}

// ---------- install / sync helpers ----------

/// Atomically installs [src] to [destPath]: copy to a temp file in the same
/// directory, then rename over the destination. Renaming over a RUNNING
/// executable is allowed on macOS (old inode stays mapped), while copying
/// over it fails with "Text file busy" or leaves a partial binary.
void installFileAtomically(File src, String destPath) {
  final destDir = Directory(destPath).parent;
  destDir.createSync(recursive: true);
  final tmp = File('$destPath.tmp-$pid');
  try {
    src.copySync(tmp.path);
    tmp.renameSync(destPath);
  } catch (e) {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
    fail('cannot install ${src.path} -> $destPath: $e');
  }
}

/// Generic "copy cores + manifest into [dest], chmod, de-quarantine, verify".
Future<void> syncCoresTo(
  String coresDir,
  Map<String, String> manifestFiles,
  String dest, {
  required String what,
}) async {
  log('Syncing $what: $dest');
  Directory(dest).createSync(recursive: true);

  for (final name in [...manifestFiles.keys, 'manifest.json']) {
    final src = File('$coresDir${sep}$name');
    if (!src.existsSync()) fail('missing source file: ${src.path}');
    installFileAtomically(src, '$dest${sep}$name');
  }
  for (final exe in ['sing-box', 'xray', 'helper']) {
    final p = '$dest${sep}$exe';
    if (File(p).existsSync()) chmod(p, '755');
  }
  clearQuarantine(dest);

  // verify every copied file against the manifest
  final bad = <String>[];
  for (final entry in manifestFiles.entries) {
    final f = File('$dest${sep}${entry.key}');
    if (!f.existsSync()) {
      bad.add('${entry.key} (missing after sync)');
      continue;
    }
    final actual = await sha256OfFile(f);
    if (actual != entry.value) {
      bad.add('${entry.key} (expected ${entry.value}, got $actual)');
    }
  }
  if (bad.isNotEmpty) {
    stderr.writeln('ERROR: $what verification failed in $dest');
    for (final b in bad) {
      stderr.writeln('    $b');
    }
    stderr.writeln(
      '       Close the running app (helper/sing-box/xray may '
      'hold files) and re-run, or delete the dir and retry.',
    );
    exit(1);
  }
  note('$what verified: ${manifestFiles.length} file(s)');
}

/// Syncs the cores into EXISTING App Sandbox containers:
///   ~/Library/Containers/<id>/Data/Library/Application Support/any_core_vpn/cores
///
/// A sandboxed app sees $HOME as its container Data dir, so the plain
/// ~/Library/Application Support copy is invisible to it. Only containers
/// that already have the any_core_vpn directory are touched - we never
/// create junk in unrelated containers.
Future<void> syncSandboxContainers(
  String coresDir,
  Map<String, String> manifestFiles,
) async {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    note('HOME is not set - sandbox container sync skipped');
    return;
  }
  final containers = Directory('$home${sep}Library${sep}Containers');
  if (!containers.existsSync()) {
    note('no ~/Library/Containers - sandbox container sync skipped');
    return;
  }

  var synced = 0;
  for (final entry in containers.listSync()) {
    if (entry is! Directory) continue;
    final base =
        '${entry.path}${sep}Data${sep}Library${sep}Application Support${sep}$_runtimeDirName';
    if (!Directory(base).existsSync()) continue;

    await syncCoresTo(
      coresDir,
      manifestFiles,
      '$base${sep}cores',
      what: 'sandbox container copy (${baseName(entry.path)})',
    );
    synced++;
  }

  if (synced == 0) {
    note(
      'no existing sandbox containers for "$_runtimeDirName" found '
      '(run the app once, then re-run this script if needed)',
    );
  } else {
    note('sandbox containers synced: $synced');
  }
}

/// Finds the SwiftPM target sources dir of this plugin:
/// <pluginRoot>/macos/<pkg>/Package.swift -> <pkg>/Sources/<target>.
/// SwiftPM only packs resources that live INSIDE the target dir, so cores
/// from <pluginRoot>/macos/cores are copied there (see syncSwiftPmResources).
String? findSwiftPmSourcesDir(String pluginRoot) {
  final macosDir = Directory('$pluginRoot${sep}macos');
  if (!macosDir.existsSync()) return null;

  for (final e in macosDir.listSync()) {
    if (e is! Directory) continue;
    if (!File('${e.path}${sep}Package.swift').existsSync()) continue;

    final sources = Directory('${e.path}${sep}Sources');
    if (!sources.existsSync()) continue;
    for (final t in sources.listSync()) {
      if (t is Directory) return t.path; // plugin has exactly one target
    }
  }
  return null;
}

Future<void> syncSwiftPmResources(
  String coresDir,
  Map<String, String> manifestFiles,
  String pluginRoot,
) async {
  final sourcesDir = findSwiftPmSourcesDir(pluginRoot);
  if (sourcesDir == null) {
    note(
      'SwiftPM package layout not found under macos/ - bundle sync skipped '
      '(CocoaPods-only plugin: bundle comes from podspec resource_bundles)',
    );
    return;
  }
  await syncCoresTo(
    coresDir,
    manifestFiles,
    '$sourcesDir${sep}Resources${sep}cores',
    what: 'SwiftPM bundle resources',
  );
  note(
    'Make sure Package.swift declares: resources: [.copy("Resources/cores")]',
  );
  note('Rebuild the app (flutter clean) so the resource bundle is repacked.');
}

// ---------- main ----------

Future<void> main(List<String> argv) async {
  final scriptDir = File.fromUri(Platform.script).parent; // <root>/tool/macos
  final pluginRoot = scriptDir.parent.parent; // <root>

  var configFile = '${pluginRoot.path}${sep}setup_cores.json';
  var coresDir =
      Platform.environment['VPN_CORES_DIR'] ??
      '${pluginRoot.path}${sep}macos${sep}cores';
  var runtimeDir =
      '${Platform.environment['HOME'] ?? ''}${sep}Library${sep}Application Support${sep}$_runtimeDirName${sep}cores';
  var xrayVersion = '';
  var singboxVersion = '';
  var skipRuntimeSync = false;
  var skipBundleSync = false;
  var skipContainers = false;
  var skipHelper = false;

  for (var i = 0; i < argv.length; i++) {
    String next(String flag) {
      if (i + 1 >= argv.length) fail('$flag requires a value');
      return argv[++i];
    }

    switch (argv[i]) {
      case '--xray-version':
        xrayVersion = next('--xray-version');
        break;
      case '--singbox-version':
        singboxVersion = next('--singbox-version');
        break;
      case '--cores-dir':
        coresDir = next('--cores-dir');
        break;
      case '--config':
        configFile = next('--config');
        break;
      case '--runtime-dir':
        runtimeDir = next('--runtime-dir');
        break;
      case '--skip-runtime-sync':
        skipRuntimeSync = true;
        break;
      case '--skip-bundle-sync':
        skipBundleSync = true;
        break;
      case '--skip-containers':
        skipContainers = true;
        break;
      case '--skip-helper':
        skipHelper = true;
        break;
      case '-h':
      case '--help':
        stdout.writeln(_usage);
        exit(0);
      default:
        fail('unknown argument: ${argv[i]}');
    }
  }

  // ---------- platform checks ----------
  selfTestSha256();
  log('Checking environment');
  if (!Platform.isMacOS) {
    fail('macOS required (running on ${Platform.operatingSystem})');
  }
  final arch = runCapture('uname', ['-m']) ?? '';
  if (arch != 'arm64') {
    fail('Apple Silicon only (got ${arch.isEmpty ? 'unknown' : arch})');
  }
  note('platform : macOS ${Platform.operatingSystemVersion} ($arch)');

  for (final cmd in ['tar', 'ditto', 'xcrun']) {
    final p = resolveCommand(cmd);
    if (p == null) fail("'$cmd' not found (install Xcode command line tool)");
    note('$cmd : $p');
  }

  // ---------- versions ----------
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

  if (singboxVersion.isEmpty) singboxVersion = jsonGet('singboxVersion');
  if (xrayVersion.isEmpty) xrayVersion = jsonGet('xrayVersion');

  final sbTag = 'v${singboxVersion.replaceFirst(RegExp('^v'), '')}';
  final xrTag = 'v${xrayVersion.replaceFirst(RegExp('^v'), '')}';
  note('sing-box : $sbTag');
  note('xray     : $xrTag');

  Directory(coresDir).createSync(recursive: true);
  note('cores dir : $coresDir');

  // ---------- expected digests from GitHub ----------
  log('Fetching release digests from GitHub');
  final sbAsset = 'sing-box-$singboxVersion-darwin-arm64.tar.gz';
  final xrAsset = 'Xray-macos-arm64-v8a.zip';

  final sbDigest = await assetSha256('SagerNet/sing-box', sbTag, sbAsset);
  final xrDigest = await assetSha256('XTLS/Xray-core', xrTag, xrAsset);
  note('$sbAsset : $sbDigest');
  note('$xrAsset : $xrDigest');

  // ---------- download + verify ----------
  final tmp = Directory.systemTemp.createTempSync('macos-cores-');
  try {
    await downloadVerified(
      sbAsset,
      'https://github.com/SagerNet/sing-box/releases/download/$sbTag/$sbAsset',
      sbDigest,
      File('${tmp.path}${sep}sing-box.tar.gz'),
    );
    await downloadVerified(
      xrAsset,
      'https://github.com/XTLS/Xray-core/releases/download/$xrTag/$xrAsset',
      xrDigest,
      File('${tmp.path}${sep}xray.zip'),
    );

    // ---------- extract ----------
    log('Extracting archives');
    final sbDir = '${tmp.path}${sep}sb';
    final xrDir = '${tmp.path}${sep}xr';
    Directory(sbDir).createSync(recursive: true);
    Directory(xrDir).createSync(recursive: true);

    await runOrDie('tar', [
      '-xzf',
      '${tmp.path}${sep}sing-box.tar.gz',
      '-C',
      sbDir,
    ], error: 'cannot extract sing-box archive');
    await runOrDie('ditto', [
      '-x',
      '-k',
      '${tmp.path}${sep}xray.zip',
      xrDir,
    ], error: 'cannot extract Xray archive');

    final sbBin = findFirst(sbDir, 'sing-box');
    final xrBin = findFirst(xrDir, 'xray');
    if (sbBin == null || xrBin == null) {
      fail(
        'Executables not found in archives '
        '(sing-box: ${sbBin?.path ?? 'missing'}, xray: ${xrBin?.path ?? 'missing'})',
      );
    }
    note('sing-box bin : ${sbBin.path}');
    note('xray bin     : ${xrBin.path}');

    // ---------- install (canonical dir) ----------
    log('Installing cores into $coresDir');
    installFileAtomically(sbBin, '$coresDir${sep}sing-box');
    installFileAtomically(xrBin, '$coresDir${sep}xray');

    for (final geo in ['geoip.dat', 'geosite.dat']) {
      final f = findFirst(xrDir, geo);
      if (f != null) {
        installFileAtomically(f, '$coresDir${sep}$geo');
        note('geo file : $geo');
      } else {
        warn('$geo not found in the Xray archive (skipped)');
      }
    }

    chmod('$coresDir${sep}sing-box', '755');
    chmod('$coresDir${sep}xray', '755');

    // ---------- supervisor ----------
    if (!skipHelper) {
      log('Compiling supervisor (helper.swift)');
      final helperSrc =
          '${pluginRoot.path}${sep}tool${sep}macos${sep}helper.swift';
      if (!File(helperSrc).existsSync()) {
        fail('helper.swift not found: $helperSrc');
      }
      await runOrDie('xcrun', [
        'swiftc',
        '-swift-version',
        '5',
        '-O',
        '-target',
        'arm64-apple-macos12.0',
        helperSrc,
        '-o',
        '$coresDir${sep}helper',
      ], error: 'swiftc failed to compile helper.swift');
      chmod('$coresDir${sep}helper', '755');
    } else {
      note('helper compilation skipped (--skip-helper)');
    }

    clearQuarantine(coresDir);

    // ---------- manifest ----------
    log('Writing manifest.json');
    final names = ['sing-box', 'xray', 'geoip.dat', 'geosite.dat', 'helper'];
    final files = <String, String>{};
    for (final name in names) {
      final f = File('$coresDir${sep}$name');
      if (!f.existsSync()) fail('missing: $name');
      files[name] = await sha256OfFile(f);
    }
    final manifest = {
      'version': 1,
      'singbox': singboxVersion,
      'xray': xrayVersion,
      'files': files,
    };
    File(
      '$coresDir${sep}manifest.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
    for (final e in files.entries) {
      note('${e.value}  ${e.key}');
    }

    // ---------- SwiftPM bundle resources ----------
    if (!skipBundleSync) {
      await syncSwiftPmResources(coresDir, files, pluginRoot.path);
    } else {
      note('SwiftPM bundle sync skipped (--skip-bundle-sync)');
    }

    // ---------- runtime copy ----------
    if (!skipRuntimeSync) {
      await syncCoresTo(coresDir, files, runtimeDir, what: 'runtime copy');
    } else {
      note('runtime sync skipped (--skip-runtime-sync)');
    }

    // ---------- sandbox containers (only when the app is sandboxed) ----------
    if (!skipContainers) {
      await syncSandboxContainers(coresDir, files);
    } else {
      note('sandbox container sync skipped (--skip-containers)');
    }

    log('Done. Cores installed to: $coresDir');
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }
}
