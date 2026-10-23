#!/usr/bin/env dart
//
// check_macos_cores.dart
// Verifies that the macOS cores (sing-box, xray, helper, geoip/geosite)
// are present in <plugin_root>/macos/cores and match manifest.json checksums.
//
// Designed to be called from the Xcode "Run Script" build phase:
//   "$DART" "$PLUGIN_ROOT/tools/macos/check_macos_cores.dart"
// Exit code 0 = OK, 1 = missing/corrupt (fails the Xcode build).
//
// Options:
//   --cores-dir <path>   cores dir (default: <plugin_root>/macos/cores,
//                        or $VPN_CORES_DIR if set)
//   --quiet              print only errors / a single OK line
//   -h, --help           show help

import 'dart:convert';
import 'dart:io';

import 'cores_common.dart';

const _usage = '''
check_macos_cores.dart - verify macOS cores integrity

Usage:
  dart tools/macos/check_macos_cores.dart [--cores-dir <path>] [--quiet]

Exit codes:
  0  cores present and checksums match
  1  cores missing, manifest missing or checksum mismatch
''';

Future<void> main(List<String> argv) async {
  // <plugin_root>/tools/macos/this_file.dart
  final scriptDir = File.fromUri(Platform.script).parent;
  final pluginRoot = scriptDir.parent.parent;

  var coresDir = '';
  var quiet = false;

  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--cores-dir':
        if (i + 1 >= argv.length) fail('--cores-dir requires a value');
        coresDir = argv[++i];
        break;
      case '--quiet':
      case '-q':
        quiet = true;
        break;
      case '-h':
      case '--help':
        stdout.writeln(_usage);
        exit(0);
      default:
        fail('unknown argument: ${argv[i]}');
    }
  }

  if (coresDir.isEmpty) {
    coresDir = Platform.environment['VPN_CORES_DIR'] ??
        '${pluginRoot.path}${sep}macos${sep}cores';
  }

  void say(String m) {
    if (!quiet) note(m);
  }

  final manifestFile = File('$coresDir${sep}manifest.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln('ERROR: macOS cores missing or corrupt in $coresDir');
    stderr.writeln('       (manifest.json not found)');
    stderr.writeln('       Run: flutter pub run any_core_vpn:setup_macos_cores');
    exit(1);
  }

  Map<String, dynamic> manifest;
  try {
    manifest =
        Map<String, dynamic>.from(jsonDecode(manifestFile.readAsStringSync()));
  } catch (e) {
    stderr.writeln('ERROR: cannot parse ${manifestFile.path}: $e');
    exit(1);
  }

  final files = manifest['files'];
  if (files is! Map) {
    stderr.writeln('ERROR: manifest.json has no "files" map');
    exit(1);
  }

  say('cores dir : $coresDir');
  say('sing-box  : ${manifest['singbox'] ?? '?'}');
  say('xray      : ${manifest['xray'] ?? '?'}');

  final bad = <String>[];
  for (final entry in files.entries) {
    final name = entry.key;
    final expected = entry.value is String ? entry.value as String : '';
    final f = File('$coresDir${sep}$name');
    if (!f.existsSync()) {
      bad.add('$name (missing)');
      continue;
    }
    final actual = await sha256OfFile(f);
    if (actual != expected) {
      bad.add('$name (checksum mismatch: expected $expected, got $actual)');
      continue;
    }
    say('OK  $name  ${humanSize(f.lengthSync())}');
  }

  if (bad.isNotEmpty) {
    stderr.writeln('ERROR: macOS cores missing or corrupt in $coresDir');
    for (final b in bad) {
      stderr.writeln('    $b');
    }
    stderr.writeln('Run: flutter pub run any_core_vpn:setup_macos_cores');
    exit(1);
  }

  stdout.writeln(quiet
      ? 'macOS cores OK ($coresDir)'
      : '==> macOS cores OK: ${files.length} file(s) verified in $coresDir');
}