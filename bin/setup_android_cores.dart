// Entry point for: dart run any_core_vpn:setup_android_cores
// Forwards ALL arguments to tools/android/setup_android_cores.dart.

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
  'Build libXray.aar (XTLS/libXray + Xray-core) and libbox.aar '
  '(SagerNet/sing-box) and install them into <plugin_root>/android/libs, '
  'where Gradle picks them up. Also downloads the prebuilt hev-socks5-tunnel '
  '.aar and installs libhev-socks5-tunnel.so for arm64-v8a/armeabi-v7a/x86/'
  'x86_64 into <plugin_root>/android/src/main/jniLibs/. ALWAYS produces '
  'prod-ready (stripped, -s -w) .aar files. Versions come from '
  'setup_cores.json (plugin root). '
  'Requires: git, python3, Go 1.22+, JDK 17+, Android SDK with NDK, '
  'ANDROID_HOME exported; unzip (or bsdtar / PowerShell) for the hev .aar. '
  'First run is slow (clones repos and runs "gomobile init"); next runs '
  'reuse the git cache and the cached hev .aar.',
  args: [
    ['--xray-version <ver>', 'Xray-core version/tag (overrides config)'],
    ['--singbox-version <ver>', 'sing-box version/tag (overrides config)'],
    [
      '--hev-version <ver>',
      'hev-socks5-tunnel release tag, e.g. 2.18.0 '
          '(overrides androidHevVersion from setup_cores.json)',
    ],
    ['--skip-hev', 'skip hev-socks5-tunnel download/install'],
    [
      '--libxray-ref <ref>',
      'libXray git ref (default: tag matching xray-version)',
    ],
    [
      '--out-dir <path>',
      'output dir for .aar files (default: <plugin_root>/android/libs)',
    ],
    [
      '--work-dir <path>',
      'git cache dir (default: <project>/.dart_tool/android-cores-cache)',
    ],
    ['--config <path>', 'path to an alternative setup_cores.json'],
    ['--skip-mobile-init', 'skip "gomobile init" (use if it was run before)'],
    [
      '--optimize-size',
      'prod-size preset: arm64-only ABIs + prune server-side '
          'sing-box tags (dhcp/acme/reality_server/tailscale; clash_api is KEPT '
          'because the app polls it for stats). Full LIMITATIONS banner is '
          'printed after the build; xray is stripped in every mode',
    ],
    [
      '--custom-xray-build-flags "<flags>"',
      'extra args appended to libXray gomobile bind '
          '(whitespace-separated, e.g. "-tags=foo")',
    ],
    [
      '--custom-singbox-build-flags "<flags>"',
      'extra args appended to build_libbox, '
          'e.g. "-platform android/arm64,android/arm" (custom -platform overrides preset)',
    ],
    [
      'SINGBOX_DROP_TAGS (env)',
      'override the prune drop-list for one run; '
          '"" disables pruning (ABI restriction stays)',
    ],
    ['SKIP_HEV=1 (env)', 'same as --skip-hev'],
    ['NDK=<path> (env)', 'override the NDK used by the sing-box build'],
  ],
  order: 10,
)
Future<void> main(List<String> argv) async {
  final pluginRoot = await resolvePluginRoot();
  final script = '$pluginRoot/tools/android/setup_android_cores.dart';

  if (!File(script).existsSync()) {
    stderr.writeln('ERROR: script not found: $script');
    exit(1);
  }

  // Default work dir would land inside the pub cache; move it to the
  // caller's project. Out dir stays <pluginRoot>/android/libs.
  final defaultWorkDir =
      '${Directory.current.absolute.path}/.dart_tool/android-cores-cache';
  final hasWorkDirArg = argv.contains('--work-dir');

  final forwarded = [
    if (!hasWorkDirArg) ...['--work-dir', defaultWorkDir],
    ...argv,
  ];

  stdout.writeln('==> plugin root : $pluginRoot');
  stdout.writeln('==> dart run $script ${forwarded.join(' ')}');

  final p = await Process.start(Platform.resolvedExecutable, [
    'run',
    script,
    ...forwarded,
  ], mode: ProcessStartMode.inheritStdio);
  exitCode = await p.exitCode;
}
