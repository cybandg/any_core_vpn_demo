import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:any_core_vpn/meta_service_configs/specific_configs/connection_mode_config.dart';
import 'package:any_core_vpn/vpn_service/configs/core_versions.dart';
import 'package:any_core_vpn/vpn_service/realisations/macos/macos_geo_assets.dart';
import 'package:any_core_vpn/vpn_service/realisations/macos/macos_privileged_launcher.dart';
import 'package:path/path.dart' as p;
import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/config_builders/core_config_builder.dart';
import 'package:any_core_vpn/vpn_service/link_parsers/link_parser.dart';
import 'package:any_core_vpn/vpn_service/rules/vpn_rules_service.dart';
import 'package:any_core_vpn/vpn_service/vpn_service.dart';

import 'macos_cores.dart';

class MacOSVpnService extends VpnService {
  static MacOSVpnService? _owner;

  final VpnCore? core;
  final ConnectionMode? connectionMode;
  final TunConfig tunConfig;
  final String? rulesPreset;
  final OutboundGroup? outboundGroup;
  final List<RoutingRule>? rulesOverride;
  final List<String> osDnsServers;
  final MacosCoresLocator coresLocator;
  final MacosEnvironmentGuard environmentGuard;

  final StreamController<String> _logs = StreamController<String>.broadcast();

  Future<void> _queue = Future<void>.value();

  MacosCoreFiles? _files;
  Directory? _session;
  Process? _launcher;
  Future<int>? _exit;
  Timer? _timer;

  bool _finished = true;
  bool _polling = false;
  bool _disposed = false;

  int _logOffset = 0;
  int? _httpPort;
  int? _socksPort;

  String _launcherError = '';

  CoreVersions? _versions;

  MacOSVpnService({
    this.core,
    this.connectionMode,
    this.tunConfig = const TunConfig(),
    this.rulesPreset,
    this.outboundGroup,
    this.rulesOverride,
    this.osDnsServers = const ['1.1.1.1', '8.8.8.8'],
    this.coresLocator = const MacosCoresLocator(),
    this.environmentGuard = const MacosEnvironmentGuard(),
  });

  @override
  Stream<String> get logStream => _logs.stream;

  String? get sessionDirectory => _session?.path;

  int? get httpPort => _httpPort;

  int? get socksPort => _socksPort;

  @override
  Future<void> init() async {
    await super.init();
    _files = await coresLocator.locate();
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());

    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});

    return result;
  }

  @override
  Future<bool> connect(String link) {
    return _serialized(() => _connect(link));
  }

  /// Dumb direct path, macOS edition: the caller's config IS the source of truth.
  ///
  ///  - No builder, no routing presets, no post-hoc rewriting (verbatim).
  ///  - The core is DETECTED from the config shape (xray uses "protocol",
  ///    sing-box uses "type") and wins over the global selection, so a config
  ///    can never be fed to the wrong binary.
  ///  - Mode is derived: tun inbound only => tunnel, proxy inbound only =>
  ///    systemProxy, both => honour the selected ConnectionMode.
  ///  - In systemProxy mode the SOCKS port is READ FROM THE CONFIG: the helper
  ///    publishes exactly these ports as the system proxy, so inventing a free
  ///    port here would point macOS at a dead listener.
  ///  - The core's own `-test` pass still runs (that is the binary's verdict,
  ///    not our validator) and its message is surfaced verbatim.
  @override
  Future<bool> connectViaConfig(Map<String, dynamic> config) {
    return _serialized(() => _connectViaConfig(config));
  }

  Future<bool> _connectViaConfig(Map<String, dynamic> config) async {
    await _acquireSession();

    try {
      final detected = _detectCore(config);
      final selected = core ?? MetaServiceConfigs.inst.selectedVpnCore.value;
      if (detected != null && detected != selected) {
        _emit(
          'Config looks like ${detected.name}, not $selected.name — '
          'using ${detected.name}',
        );
      }
      final selectedCore = detected ?? selected;

      final hasTun = _hasInbound(config, kinds: const ['tun']);
      final hasProxy = _hasInbound(
        config,
        kinds: const ['socks', 'http', 'mixed'],
      );

      final ConnectionMode mode;
      if (hasTun && !hasProxy) {
        mode = ConnectionMode.tunnel;
      } else if (!hasTun && hasProxy) {
        mode = ConnectionMode.systemProxy;
      } else if (hasTun) {
        // Both present: the user's global choice decides (same as connect()).
        mode =
            connectionMode ??
            MetaServiceConfigs.inst.sellectedConnectionMode.value;
      } else {
        throw ArgumentError(
          'connectViaConfig: the config has neither a tun inbound nor a '
          'socks/http/mixed inbound — nothing to route traffic through',
        );
      }

      // Ports must match what the core will ACTUALLY listen on.
      int? socksPort = _inboundPort(config, kinds: const ['socks', 'mixed']);
      int? httpPort = _inboundPort(config, kinds: const ['http', 'mixed']);

      if (mode == ConnectionMode.systemProxy && socksPort == null) {
        throw ArgumentError(
          'connectViaConfig: systemProxy mode needs a socks (or mixed) inbound '
          'with an explicit listen_port in the config',
        );
      }
      socksPort ??= await _freePort();
      if (httpPort == null) {
        // No HTTP listener in the config: publish 0 so the helper does not
        // point the system HTTP proxy at a dead port.
        _emit(
          'No http/mixed inbound in the config — system HTTP proxy disabled',
        );
        httpPort = 0;
      }

      if (selectedCore == VpnCore.xray && mode == ConnectionMode.tunnel) {
        final tun = _firstInbound(config, kinds: const ['tun']);
        final settings = (tun?['settings'] as Map?)?.cast<String, dynamic>();
        if (settings != null && settings['autoSystemRoutingTable'] == null) {
          _emit(
            'WARNING: xray tun inbound has no autoSystemRoutingTable — '
            'the TUN will come up but macOS routes may not be installed',
          );
        }
      }

      return await _startSession(
        selectedCore: selectedCore,
        mode: mode,
        config: config,
        httpPort: httpPort,
        socksPort: socksPort,
      );
    } catch (error, stack) {
      try {
        await _stop();
      } catch (cleanupError) {
        _emit('Cleanup error: $cleanupError');
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<bool> _connect(String link) async {
    await _acquireSession();

    try {
      final selectedCore =
          core ?? MetaServiceConfigs.inst.selectedVpnCore.value;
      // BUGFIX: this used to read `selectedVpnCore.value`, which made the
      // expression type Object and forced the systemProxy branch on every
      // default-mode connect.
      final selectedConnectionMode =
          connectionMode ??
          MetaServiceConfigs.inst.sellectedConnectionMode.value;

      if (tunConfig.includedApps.isNotEmpty ||
          tunConfig.excludedApps.isNotEmpty) {
        throw UnsupportedError(
          'includedApps and excludedApps are Android-only.',
        );
      }

      for (final server in osDnsServers) {
        if (InternetAddress.tryParse(server) == null) {
          throw ArgumentError(
            'osDnsServers must contain IP addresses, not DNS URLs.',
          );
        }
      }

      final node = LinkParser.createParserForLink(link).parseLink(link);

      if (selectedCore == VpnCore.singbox &&
          node.protocol == ProtocolTypes.wireguard) {
        throw UnsupportedError(
          'The supplied SingboxConfigBuilder generates a legacy '
          'WireGuard outbound. Migrate it to a WireGuard endpoint first.',
        );
      }

      if (node.params['plugin']?.isNotEmpty ?? false) {
        throw UnsupportedError(
          'External Shadowsocks plugins are not supported by this runner.',
        );
      }

      if (selectedCore == VpnCore.xray && outboundGroup != null) {
        throw UnsupportedError(
          'Xray outbound groups require a separate builder migration.',
        );
      }

      final rules =
          rulesOverride ?? await VpnRulesService.instance.rulesFor(rulesPreset);

      for (final rule in rules) {
        if (rule.sourceApps.isNotEmpty) {
          throw UnsupportedError(
            'Android package routing cannot be used on macOS.',
          );
        }

        if (selectedCore == VpnCore.singbox &&
            (rule.domainSets.isNotEmpty || rule.ipSets.isNotEmpty)) {
          throw UnsupportedError(
            'sing-box 1.14 requires rule_set instead of geoip/geosite.',
          );
        }
      }

      final httpPort = _httpPort = await _freePort();

      var socksPort = await _freePort();
      while (socksPort == httpPort) {
        socksPort = await _freePort();
      }
      _socksPort = socksPort;

      final VpnCoreConfigBuilder builder = selectedCore == VpnCore.singbox
          ? SingboxConfigBuilder(isDesktop: true, inboundTag: 'tun-in')
          : XrayConfigBuilder(httpPort: httpPort, socksPort: socksPort);

      builder.validateProtocolSupported(node, SupportedPlatforms.macos);

      final config = builder.buildConfig(
        nodes: [node],
        activeGroup: outboundGroup,
        customRules: rules,
        tunConfig: tunConfig,
      );

      if (selectedCore == VpnCore.singbox) {
        config.remove('experimental');
        config['log'] = {'level': 'info', 'timestamp': true};

        config['inbounds'] = [
          if (selectedConnectionMode == ConnectionMode.tunnel)
            {
              'type': 'tun',
              'tag': 'tun-in',
              'address': [
                tunConfig.inet4Address,
                if (tunConfig.inet6Address.isNotEmpty) tunConfig.inet6Address,
              ],
              'mtu': tunConfig.mtu,
              'stack': tunConfig.stack.name,
              'auto_route': true,
              'strict_route': tunConfig.strictRoute,
            },
          {
            'type': 'mixed',
            'tag': 'proxy-in',
            'listen': '127.0.0.1',
            'listen_port': httpPort,
          },
          {
            'type': 'socks',
            'tag': 'socks-in',
            'listen': '127.0.0.1',
            'listen_port': socksPort,
          },
        ];

        final route = config['route'] as Map<String, dynamic>;
        route['final'] = outboundGroup?.tag ?? node.name;
        route['auto_detect_interface'] = true;

        for (final value in route['rules'] as List) {
          final rule = value as Map<String, dynamic>;

          if (rule['action'] == 'sniff') {
            rule['inbound'] = ['tun-in', 'proxy-in', 'socks-in'];
          }
        }

        final dns = config['dns'] as Map<String, dynamic>;
        final servers = dns['servers'] as List;

        for (var index = 0; index < servers.length; index++) {
          if ((servers[index] as Map)['tag'] == 'local-dns') {
            servers[index] = {
              'type': 'udp',
              'tag': 'local-dns',
              'server': '1.1.1.1',
            };
          }
        }
      } else {
        config['log'] = {'loglevel': 'info'};

        final inbounds = (config['inbounds'] as List)
            .where((value) => (value as Map)['protocol'] != 'tun')
            .toList();

        if (selectedConnectionMode == ConnectionMode.tunnel) {
          inbounds.insert(0, {
            'tag': 'tun-in',
            'protocol': 'tun',
            'settings': {
              'mtu': tunConfig.mtu,
              'gateway': [
                tunConfig.inet4Address,
                if (tunConfig.inet6Address.isNotEmpty) tunConfig.inet6Address,
              ],
              'autoSystemRoutingTable': [
                '0.0.0.0/0',
                if (tunConfig.inet6Address.isNotEmpty) '::/0',
              ],
              'autoOutboundsInterface': 'auto',
            },
            'sniffing': {
              'enabled': tunConfig.enableSniffing,
              'destOverride': ['http', 'tls', 'quic'],
            },
          });
        }

        config['inbounds'] = inbounds;
      }

      return await _startSession(
        selectedCore: selectedCore,
        mode: selectedConnectionMode,
        config: config,
        httpPort: httpPort,
        socksPort: socksPort,
      );
    } catch (error, stack) {
      try {
        await _stop();
      } catch (cleanupError) {
        _emit('Cleanup error: $cleanupError');
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  /// Shared guard for BOTH entry points: one owner, clean network, no leftovers.
  Future<void> _acquireSession() async {
    if (_disposed) {
      throw StateError('Service has been disposed');
    }

    if (_owner != null && _owner != this) {
      throw const VpnEnvironmentException(
        'Другая сессия этого плагина уже активна. Завершите её и повторите.',
      );
    }

    await environmentGuard.assertClean();
    await _stop();
    _owner = this;
  }

  /// Shared tail for BOTH entry points: session dir, config.json, core -test,
  /// manifest, privileged helper launch, readiness wait.
  ///
  /// Launch path: `sudo -n <root wrapper>` when the one-time password-free
  /// install is present, otherwise the osascript admin dialog (as before).
  Future<bool> _startSession({
    required VpnCore selectedCore,
    required ConnectionMode mode,
    required Map<String, dynamic> config,
    required int httpPort,
    required int socksPort,
  }) async {
    _files = await coresLocator.locate();

    final privileged = MacosPrivilegedLauncher.instance;
    final passwordless = await privileged.isPasswordlessReady;

    // When the sudoers wrapper is installed it only accepts the PINNED,
    // root-owned binaries — so the manifest must reference them too.
    final pinned = passwordless
        ? privileged.pinnedBinaryFor(selectedCore)
        : null;

    final binary =
        pinned ??
        (selectedCore == VpnCore.singbox ? _files!.singbox : _files!.xray);

    final home = Platform.environment['HOME'];

    if (home == null || home.isEmpty) {
      throw StateError('HOME is not set');
    }

    final sessions = Directory(
      p.join(
        home,
        'Library',
        'Application Support',
        'any_core_vpn',
        'sessions',
      ),
    );

    await sessions.create(recursive: true);

    final session = _session = await sessions.createTemp('session-');

    await Process.run('/bin/chmod', ['700', session.path]);

    _httpPort = httpPort;
    _socksPort = socksPort;

    // SHALLOW COPY on purpose: runtime env injection below must never mutate
    // the caller's map (connectViaConfig hands us the user's verbatim config).
    final cfg = Map<String, dynamic>.from(config);

    // ---- geo databases for geosite:/geoip: rules (xray only) ----
    // The macOS core binaries ship WITHOUT geo data, and Xray's default
    // lookup dir is the executable's own folder (the pinned root dir or the
    // bundle) — hence "stat .../geosite.dat: no such file or directory".
    // Same runtime injection the Android native side performs: point the
    // core at a stable user directory via the config-root env.
    if (selectedCore == VpnCore.xray) {
      final geoDir = await MacosGeoAssets.ensure(log: _emit);
      if (geoDir != null) {
        final env = (cfg['env'] as Map?)?.cast<String, dynamic>() ?? {};
        env['xray.location.asset'] = geoDir;
        env['xray.conf.geoloader'] = 'memconservative';
        env['xray.conf.geositeMatcher'] = 'succinct';
        cfg['env'] = env;
      } else {
        _emit(
          'WARNING: geo databases unavailable — geosite:/geoip: rules will '
          'fail to load',
        );
      }
    }

    final configFile = File(p.join(session.path, 'config.json'));

    await configFile.writeAsString(jsonEncode(cfg));
    await Process.run('/bin/chmod', ['600', configFile.path]);

    // The core's OWN verdict on the config — not a hand-written validator.
    // Runs unprivileged: `-test` / `check` never touch the network stack.
    await Process.run(
      binary,
      selectedCore == VpnCore.singbox
          ? ['check', '-c', configFile.path]
          : ['run', '-test', '-config', configFile.path],
    ).then((result) {
      if (result.exitCode != 0) {
        throw StateError(
          'Config rejected by ${selectedCore.name}: '
          '${result.stdout}\n${result.stderr}',
        );
      }
    });

    await File(p.join(session.path, 'core.log')).writeAsString('');

    await File(p.join(session.path, 'manifest.json')).writeAsString(
      jsonEncode({
        'core': selectedCore.name,
        'binary': binary,
        'mode': mode.name,
        'ownerPid': pid,
        'httpPort': httpPort,
        'socksPort': socksPort,
        'osDnsServers':
            mode == ConnectionMode.tunnel && tunConfig.enableDnsHijacking
            ? osDnsServers
            : <String>[],
      }),
    );

    _logOffset = 0;
    _launcherError = '';
    _finished = false;

    _heartbeat();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _heartbeat();
      unawaited(_pollLogs());
    });

    // Fallback path (unchanged): AppleScript with the admin password dialog.
    final helperForFallback = pinned ?? _files!.helper;
    final command = [
      helperForFallback,
      'run',
      session.path,
    ].map(_shellQuote).join(' ');

    final script =
        'do shell script ${_appleScriptQuote(command)} '
        'with administrator privileges';

    _emit(
      'Starting ${selectedCore.name}/${mode.name} '
      '(${passwordless ? 'password-free sudo' : 'admin password required'})',
    );
    _emit('Session: ${session.path}');

    final launcher = _launcher = await privileged.startSupervisor(
      sessionPath: session.path,
      fallbackAppleScript: script,
    );

    unawaited(launcher.stdout.drain<void>());

    unawaited(
      launcher.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach((chunk) {
            _launcherError += chunk;
            _emit(chunk);
          }),
    );

    _exit = launcher.exitCode.then((code) {
      _finished = true;
      _emit('Supervisor exited: $code');
      return code;
    });

    final deadline = DateTime.now().add(const Duration(minutes: 2));

    while (DateTime.now().isBefore(deadline)) {
      final state = await _readState();

      if (state['state'] == 'ready' && !_finished) {
        _emit('VPN ready');
        return true;
      }

      if (state['state'] == 'failed' || _finished) {
        final error = (state['error'] ?? 'Supervisor exited').toString();

        if (error.contains('Другой VPN уже активен') ||
            error.contains('В системе уже включён прокси')) {
          throw VpnEnvironmentException(error);
        }

        throw StateError(
          '$error\n$_launcherError\n'
          'Logs: ${p.join(session.path, 'core.log')}',
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    throw TimeoutException('VPN startup or administrator approval timed out');
  }
  
  // ---------------- config introspection (shape sniffing, no validation) ----

  /// xray inbounds carry "protocol", sing-box inbounds carry "type".
  /// Both are present in the same list position, so one pass decides the core.
  static VpnCore? _detectCore(Map<String, dynamic> config) {
    final inbounds = config['inbounds'];
    if (inbounds is! List) return null;

    for (final raw in inbounds) {
      if (raw is! Map) continue;
      if (raw.containsKey('protocol')) return VpnCore.xray;
      if (raw.containsKey('type')) return VpnCore.singbox;
    }
    return null;
  }

  static List<Map<String, dynamic>> _inbounds(Map<String, dynamic> config) {
    final raw = config['inbounds'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
  }

  /// Matches an inbound by its protocol/type name across both dialects.
  static bool _hasInbound(
    Map<String, dynamic> config, {
    required List<String> kinds,
  }) {
    return _inbounds(
      config,
    ).any((ib) => kinds.contains((ib['protocol'] ?? ib['type'])?.toString()));
  }

  static Map<String, dynamic>? _firstInbound(
    Map<String, dynamic> config, {
    required List<String> kinds,
  }) {
    for (final ib in _inbounds(config)) {
      if (kinds.contains((ib['protocol'] ?? ib['type'])?.toString())) return ib;
    }
    return null;
  }

  /// Listen port of the first matching inbound: xray "port" / sing-box
  /// "listen_port". Returns null when absent — the caller decides.
  static int? _inboundPort(
    Map<String, dynamic> config, {
    required List<String> kinds,
  }) {
    for (final ib in _inbounds(config)) {
      if (!kinds.contains((ib['protocol'] ?? ib['type'])?.toString())) continue;
      final raw = ib['port'] ?? ib['listen_port'];
      final port = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
      if (port != null && port > 0) return port;
    }
    return null;
  }

  @override
  Future<void> disconnect() {
    return _serialized(_stop);
  }

  Future<void> _stop() async {
    final session = _session;
    final exit = _exit;

    if (session != null && await session.exists()) {
      await File(p.join(session.path, 'stop')).writeAsString('stop');
    }

    _timer?.cancel();
    _timer = null;

    if (exit != null) {
      try {
        await exit.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        _launcher?.kill(ProcessSignal.sigterm);
        throw StateError(
          'Supervisor did not confirm shutdown. '
          'Session retained at ${session?.path}. '
          'Do not start another session until it has stopped.',
        );
      }
    }

    await _pollLogs();

    final state = await _readState();

    _launcher = null;
    _exit = null;
    _finished = true;

    if (_owner == this) {
      _owner = null;
    }

    if (state['state'] == 'failed') {
      _emit('Session finished with an error: ${state['error']}');

      final journal = session == null
          ? null
          : File(p.join(session.path, 'network.plist'));

      if (journal != null && await journal.exists()) {
        throw StateError(
          'Network restoration requires attention: ${session!.path}',
        );
      }
    }
  }

  /// The macOS runner keeps everything inside the per-session directory, so
  /// only the core of THIS session has a dump. Returns an empty map before
  /// the first connect.
  @override
  Future<Map<VpnCore, String>> coreConfigPaths() async {
    final session = _session;
    if (session == null) return const {};

    final selectedCore = core ?? MetaServiceConfigs.inst.selectedVpnCore.value;
    return {selectedCore: p.join(session.path, 'config.json')};
  }

  @override
  Future<bool> isRunning() async {
    if (_launcher == null || _finished) {
      return false;
    }

    return (await _readState())['state'] == 'ready';
  }

  Future<void> dispose() async {
    await disconnect();
    _disposed = true;
    await _logs.close();
  }

  void _heartbeat() {
    final session = _session;

    if (session == null) {
      return;
    }

    try {
      File(
        p.join(session.path, 'heartbeat'),
      ).writeAsStringSync(DateTime.now().toIso8601String());
    } catch (error) {
      _emit('Heartbeat error: $error');
    }
  }

  Future<void> _pollLogs() async {
    if (_polling || _session == null) {
      return;
    }

    _polling = true;

    try {
      final file = File(p.join(_session!.path, 'core.log'));

      if (!await file.exists()) {
        return;
      }

      final length = await file.length();

      if (length < _logOffset) {
        _logOffset = 0;
      }

      if (length == _logOffset) {
        return;
      }

      final bytes = await file
          .openRead(_logOffset, length)
          .fold<List<int>>(<int>[], (result, chunk) => result..addAll(chunk));

      _logOffset = length;

      if (bytes.isNotEmpty) {
        _emit(utf8.decode(bytes, allowMalformed: true));
      }
    } finally {
      _polling = false;
    }
  }

  Future<Map<String, dynamic>> _readState() async {
    final session = _session;

    if (session == null) {
      return {};
    }

    final file = File(p.join(session.path, 'state.json'));

    if (!await file.exists()) {
      return {};
    }

    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  void _emit(String message) {
    if (!_logs.isClosed) {
      _logs.add(message);
    }
  }

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);

    final port = socket.port;
    await socket.close();

    return port;
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\\''")}'";
  }

  static String _appleScriptQuote(String value) {
    return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
  }

  /// Reads the binaries' own version output once and caches it.
  @override
  Future<CoreVersions> coreVersions() async {
    final cached = _versions;
    if (cached != null) return cached;

    final files = _files ?? await coresLocator.locate();

    Future<String?> read(String path, List<String> args) async {
      try {
        final result = await Process.run(path, args);
        final output = (result.stdout.toString() + result.stderr.toString())
            .trim();
        if (output.isEmpty) return null;
        final match = RegExp(r'\d+\.\d+(?:\.\d+)?').firstMatch(output);
        return match?.group(0) ?? output.split('\n').first;
      } catch (error) {
        _emit('version probe failed for $path: $error');
        return null;
      }
    }

    final singbox = await read(files.singbox, ['version']);
    final xray = await read(files.xray, ['version']);

    return _versions = CoreVersions(xray: xray, singbox: singbox);
  }
}
