// Entry point for: dart run any_core_vpn:check_cores
// Forwards ALL arguments to tools/check_cores.dart inside this package.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:any_core_vpn/src/help_annotation.dart';

// MUST match "name:" in this plugin's pubspec.yaml
const packageName = 'any_core_vpn';

Future<String> resolvePluginRoot() async {
  final libUri =
      await Isolate.resolvePackageUri(Uri.parse('package:$packageName/'));
  if (libUri != null) {
    return Directory.fromUri(libUri).parent.path; // <root>/lib -> <root>
  }

  // fallback: walk up from cwd looking for .dart_tool/package_config.json
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
  stderr.writeln('       Run "flutter pub get" and run this command '
      'from the project that depends on the plugin.');
  exit(1);
}

@HelpAnnotation(
  'Check the latest stable and pre-release versions of Xray-core and '
  'sing-box on GitHub, compare them with xrayVersion / singboxVersion '
  'from setup_cores.json (plugin root) and tell whether the plugin cores '
  'need to be rebuilt.',
  args: [
    ['GITHUB_TOKEN=<token> (env)', 'raise the GitHub API rate limit (60 req/h anonymous)'],
    ['CONFIG_FILE=<path> (env)', 'use an alternative setup_cores.json'],
  ],
  order: 20,
)
Future<void> main(List<String> argv) async {
  final pluginRoot = await resolvePluginRoot();
  final script = '$pluginRoot/tools/check_cores.dart';

  if (!File(script).existsSync()) {
    stderr.writeln('ERROR: script not found: $script');
    exit(1);
  }

  stdout.writeln('==> plugin root : $pluginRoot');
  stdout.writeln('==> dart run $script ${argv.join(' ')}');

  final p = await Process.start(
    Platform.resolvedExecutable, // same dart binary that runs this wrapper
    ['run', script, ...argv],    // <- all CLI args forwarded as-is
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await p.exitCode;
}