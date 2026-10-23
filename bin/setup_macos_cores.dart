// Entry point for: dart run any_core_vpn:setup_macos_cores
// Forwards ALL arguments to tool/macos/setup_macos_cores.dart inside this package.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:any_core_vpn/src/help_annotation.dart';

// MUST match "name:" in this plugin's pubspec.yaml
const packageName = 'any_core_vpn';

Future<String> resolvePluginRoot() async {
  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:$packageName/'),
  );
  if (libUri != null) {
    return Directory.fromUri(libUri).parent.path;
  }

  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final cfg = File('${dir.path}/.dart_tool/package_config.json');
    if (cfg.existsSync()) {
      final data = jsonDecode(cfg.readAsStringSync());
      for (final p in (data as Map)['packages'] as List) {
        if (p is Map && p['name'] == packageName && p['rootUri'] is String) {
          final resolved = Uri.file(cfg.absolute.path).resolve(p['rootUri']);
          final root = Directory.fromUri(resolved);
          if (root.existsSync()) return root.absolute.path;
        }
      }
      break;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  stderr.writeln('ERROR: cannot resolve package:$packageName/.');
  stderr.writeln(
    '       Run "flutter pub get" and run this command '
    'from the project that depends on the plugin.',
  );
  exit(1);
}

@HelpAnnotation(
  'Download prebuilt sing-box and Xray-core binaries for macOS (arm64), verify '
  'them against the sha256 digests published in the GitHub releases, compile '
  'the Swift supervisor (helper.swift) and install them into '
  '<plugin_root>/macos/cores, then sync into the SwiftPM bundle resources '
  '(so the cores are packed into the .app bundle) and into the runtime copy '
  '~/Library/Application Support/any_core_vpn/cores. Versions come from '
  'setup_cores.json (plugin root), CLI args override them. Requires: macOS on '
  'Apple Silicon, Xcode command line tool (xcrun swiftc), tar, ditto.',
  args: [
    ['--xray-version <ver>', 'Xray-core version (overrides setup_cores.json)'],
    [
      '--singbox-version <ver>',
      'sing-box version (overrides setup_cores.json)',
    ],
    [
      '--cores-dir <path>',
      'canonical install dir (default: <plugin_root>/macos/cores)',
    ],
    ['--config <path>', 'path to an alternative setup_cores.json'],
    [
      '--runtime-dir <path>',
      'runtime copy dir (default: ~/Library/Application Support/any_core_vpn/cores)',
    ],
    ['--skip-runtime-sync', 'do not create the runtime copy'],
    ['--skip-bundle-sync', 'do not copy cores into SwiftPM resources'],
    ['--skip-helper', 'do not compile helper.swift'],
    [
      'GITHUB_TOKEN=<token> (env)',
      'raise the GitHub API rate limit (60 req/h anonymous)',
    ],
    ['VPN_CORES_DIR=<path> (env)', 'same as --cores-dir'],
  ],
  order: 40,
)
Future<void> main(List<String> argv) async {
  final pluginRoot = await resolvePluginRoot();
  final script = '$pluginRoot/tool/macos/setup_macos_cores.dart';

  if (!File(script).existsSync()) {
    stderr.writeln('ERROR: script not found: $script');
    exit(1);
  }

  stdout.writeln('==> plugin root : $pluginRoot');
  stdout.writeln('==> dart run $script ${argv.join(' ')}');

  final p = await Process.start(
    Platform.resolvedExecutable,
    ['run', script, ...argv], // <- all CLI args forwarded as-is
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await p.exitCode;
}
