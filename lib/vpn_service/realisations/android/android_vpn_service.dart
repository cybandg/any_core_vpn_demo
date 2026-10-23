import 'dart:convert';
import 'dart:io';

import 'package:any_core_vpn/vpn_service/configs/core_versions.dart';
import 'package:any_core_vpn/vpn_service/configs/vpn_config_storage_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/connection_mode_config.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/config_builders/core_config_builder.dart';
import 'package:any_core_vpn/vpn_service/exceptions/vpn_service_exception.dart';
import 'package:any_core_vpn/vpn_service/link_parsers/link_parser.dart';
import 'package:any_core_vpn/vpn_service/rules/vpn_rules_service.dart';
import 'package:any_core_vpn/vpn_service/vpn_node_data.dart';
import 'package:any_core_vpn/vpn_service/vpn_service.dart';

/// Android VPN service.
///
/// ConnectionMode.tunnel      -> the core owns the TUN (tun inbound).
/// ConnectionMode.systemProxy -> Happ-style: the core exposes a loopback
///                                 SOCKS5 listener only, hev-socks5-tunnel
///                                 owns the TUN fd and bridges device traffic
///                                 into SOCKS5 (C + lwIP, no Go runtime).
class AndroidVpnService extends VpnService {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.blamurai.any_core_vpn/methods',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.blamurai.any_core_vpn/logs',
  );

  /// sing-box has exactly ONE inbound, so its tag follows the mode.
  static const String _singboxTunTag = 'tun-in';
  static const String _singboxSocksTag = 'socks-in';

  /// Resolver used for domains the active routing preset sends `direct`.
  /// Must be reachable WITHOUT the tunnel. Yandex DoH is the sane default for
  /// the shipped geo-ru presets; set null to disable the split entirely.
  final String? directDnsServer;

  /// Auto-derive the DNS split from the preset's `direct` rules.
  final bool splitDnsForDirect;

  AndroidVpnService({
    this.core,
    this.connectionMode,
    this.tunConfig = const TunConfig(),
    this.rulesPreset,
    this.rulesOverride,
    this.outboundGroup,
    this.blockQuic = true,
    this.tunnelDns = true,
    this.probeConnectivity = '',
    this.balancerFallbackTag,
    this.sniffRouteOnly = false,
    this.routingDomainStrategy = 'IPIfNonMatch',
    this.enableHealthProbe = true,
    this.clashApiPort = 0,
    this.directDnsServer = 'https://dns.google',
    this.splitDnsForDirect = true,
  }) : super();

  final VpnCore? core;
  final ConnectionMode? connectionMode;
  final TunConfig tunConfig;

  /// Preset id resolved through VpnRulesService ('geo-ru-direct', 'none', ...).
  final String? rulesPreset;

  /// Explicit rules; win over [rulesPreset]. Mirrors MacOSVpnService.
  final List<RoutingRule>? rulesOverride;

  final OutboundGroup? outboundGroup;

  final bool blockQuic;
  final bool tunnelDns;
  final String probeConnectivity;
  final String? balancerFallbackTag;
  final bool sniffRouteOnly;
  final String routingDomainStrategy;
  final bool enableHealthProbe;

  /// Clash API port for sing-box. 0 disables the external controller:
  /// a hardcoded 9090 aborts startup whenever the port is busy.
  final int clashApiPort;

  Stream<String>? _logStreamCache;

  ConnectionMode? _activeMode;
  int? _socksPort;
  int? _httpPort;

  int? get socksPort =>
      _activeMode == ConnectionMode.systemProxy ? _socksPort : null;

  int? get httpPort =>
      _activeMode == ConnectionMode.systemProxy ? _httpPort : null;

  ConnectionMode? get activeMode => _activeMode;

  CoreVersions? _cachedVersions;

  /// libbox answers immediately (main process). libXray answers only after the
  /// ":xraycore" process has reported once - that is a platform constraint,
  /// not a bug: touching LibXray from the main process would load a second Go
  /// runtime and corrupt the shared go.Seq bridge that libbox owns.
  @override
  Future<CoreVersions> coreVersions() async {
    try {
      final raw = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
        'coreVersions',
      );
      final versions = CoreVersions(
        xray: raw?['xray']?.toString(),
        singbox: raw?['singbox']?.toString(),
      );
      _cachedVersions = versions;
      VpnConfigStorageService.instance.setVersions(versions);
      _log('core versions: ${versions.describe()}');
      return versions;
    } catch (error) {
      _log('coreVersions failed: $error');
      return _cachedVersions ?? const CoreVersions();
    }
  }

  @override
  Stream<String> get logStream {
    _logStreamCache ??= _eventChannel.receiveBroadcastStream().map(
      (event) => event.toString(),
    );
    return _logStreamCache!;
  }

  ///This method checks if user accepted establishing vpn connection
  Future<bool> _prepareVpn() async {
    final bool? prepared = await _methodChannel.invokeMethod<bool>(
      'prepareVpn',
    );
    return prepared ?? false;
  }

  @override
  Future<bool> connect(String link) => connectLinks([link]);

  Future<bool> connectLinks(List<String> links) async {
    if (links.isEmpty) {
      throw ArgumentError('connectLinks requires at least one link');
    }

    final VpnCore selectedCore =
        core ?? MetaServiceConfigs.inst.selectedVpnCore.value;

    final ConnectionMode mode =
        connectionMode ?? MetaServiceConfigs.inst.sellectedConnectionMode.value;

    final bool isTunnel = mode == ConnectionMode.tunnel;

    // BOTH modes establish a VpnService TUN (in proxy mode hev owns it),
    // so the permission dialog is always required.
    if (!await _prepareVpn()) {
      throw PermissionDeniedException();
    }

    final nodes = <VpnNodeData>[];
    final seenTags = <String>{};

    for (final link in links) {
      final node = LinkParser.createParserForLink(link).parseLink(link);

      // Tags must be unique: they are balancer selector entries AND
      // Xray inbound/outbound map keys.
      var tag = node.name;
      var suffix = 2;
      while (!seenTags.add(tag)) {
        tag = '${node.name}-$suffix';
        suffix++;
      }

      nodes.add(tag == node.name ? node : node.copyWithName(tag));
    }

    int? socks;
    int? http;
    if (!isTunnel) {
      socks = await _freePort();
      http = await _freePort();
      while (http == socks) {
        http = await _freePort();
      }
    }

    final builder = _resolveConfigBuilder(
      selectedCore: selectedCore,
      isTunnel: isTunnel,
      socks: socks,
      http: http,
    );

    for (final node in nodes) {
      builder.validateProtocolSupported(node, SupportedPlatforms.android);
    }

    final customRules =
        rulesOverride ?? await VpnRulesService.instance.rulesFor(rulesPreset);

    // The builders are mode-aware: they emit either a tun inbound or the
    // loopback SOCKS5/HTTP listeners. No post-hoc JSON rewriting happens here.
    final config = builder.buildConfig(
      nodes: nodes,
      activeGroup: outboundGroup,
      customRules: customRules,
      tunConfig: tunConfig,
    );

    final exitLabel = nodes.length == 1
        ? nodes.first.name
        : '${nodes.length} nodes (leastPing)';

    final presetLabel = rulesOverride != null
        ? 'custom rules (${customRules.length})'
        : 'preset "${rulesPreset ?? VpnRulesService.instance.activePresetName}"';

    // SAME final path as connectViaConfig: the built config is just data now.
    final bool alive = await _startWithConfig(
      config: config,
      coreName: builder.core.name,
      isTunnel: isTunnel,
      socksPort: socks,
      httpPort: http,
      body: '${isTunnel ? 'TUN' : 'SOCKS5'} to $exitLabel',
    );

    if (alive) {
      // Triage aid: which preset reached the core and what it dropped.
      final projection = builder.lastProjection;
      _log('routing: $presetLabel, emitted=${projection?.rules.length ?? 0}');
      if (projection != null && projection.hasNotes) {
        for (final note in projection.dropped) {
          _log('routing dropped: $note');
        }
        for (final note in projection.lint) {
          _log('routing note: $note');
        }
      }
    }
    return alive;
  }

  void _log(String message) => debugPrint('[AnyCoreVpn] $message');

  /// In proxy mode the hev bridge carries IPv4 ONLY (no tunnel.ipv6 is
  /// configured). An "::/0" route without a matching IPv6 address makes
  /// Android derive an IPv6 DNS (fdfe:dcba:9876::2) that nobody answers:
  /// every IPv6 lookup then matches "fc00::/7 -> direct" and is blackholed,
  /// which stalls apps for seconds. Drop it.
  /// In tunnel mode the in-core stack does handle IPv6, so it stays.
  Map<String, dynamic> _tunParams(bool isTunnel) {
    final params = Map<String, dynamic>.from(tunConfig.toAndroidOsParams());
    if (isTunnel) return params;

    final routes = params['routes'];
    if (routes is List) {
      params['routes'] = routes
          .where((r) => r is Map && r['address'] != '::')
          .toList(growable: false);
    }
    return params;
  }

  /// Waits until the native side reports a running core + bridge.
  Future<bool> _waitForCore({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isRunning()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return isRunning();
  }

  @override
  Future<void> disconnect() async {
    await _methodChannel.invokeMethod('stopVpn');
    _activeMode = null;
  }

  @override
  Future<bool> isRunning() async {
    final bool? running = await _methodChannel.invokeMethod<bool>('isRunning');
    return running ?? false;
  }

  VpnCoreConfigBuilder _resolveConfigBuilder({
    required VpnCore selectedCore,
    required bool isTunnel,
    required int? socks,
    required int? http,
  }) {
    switch (selectedCore) {
      //ToDo: create a factory and cache configues.
      case VpnCore.singbox:
        return SingboxConfigBuilder(
          isDesktop: false,
          hasTunInbound: isTunnel,
          // sing-box has a single inbound, so the tag follows the mode: the
          // generated sniff rule must reference a tag that actually exists.
          inboundTag: isTunnel ? _singboxTunTag : _singboxSocksTag,
          socksPort: socks ?? 10808,
          clashApiPort: clashApiPort,
          tunnelDns: tunnelDns,
          blockQuic: blockQuic,
          // ipv4_only, NOT prefer_ipv4: prefer_ipv4 still answers AAAA, and
          // with the TUN's "::/0" route the browser then tries IPv6 first.
          // Any direct-routed IPv6 connection blackholes on a phone without
          // native IPv6 - exactly "RU sites do not open in tunnel mode".
          dnsStrategy: 'ipv4_only',
          directDnsServer: directDnsServer,
          splitDnsForDirect: splitDnsForDirect,
        );
      case VpnCore.xray:
        // NOTE: inboundTag is intentionally NOT overridden here. Xray always
        // has three inbounds (tun/socks/http) and their tags must be unique;
        // passing "tun-in" for the SOCKS inbound makes Xray reject the config
        // with "inbound tag tun-in already exists".
        return XrayConfigBuilder(
          enableTunInbound: isTunnel,
          socksPort: socks ?? 10808,
          httpPort: http ?? 10809,
          tunnelDns: tunnelDns,
          blockQuic: blockQuic,
          probeConnectivity: probeConnectivity,
          balancerFallbackTag: balancerFallbackTag,
          enableHealthProbe: enableHealthProbe,
          sniffRouteOnly: sniffRouteOnly,
          routingDomainStrategy: routingDomainStrategy,
          directDnsServer: directDnsServer,
          splitDnsForDirect: splitDnsForDirect,
        );
    }
  }

  /// Binds an ephemeral loopback port and releases it immediately.
  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  @override
  Future<bool> connectViaConfig(Map<String, dynamic> config) async {
    final VpnCore selectedCore =
        core ?? MetaServiceConfigs.inst.selectedVpnCore.value;

    final bool isTunnel = _hasTunInbound(config);

    if (!await _prepareVpn()) {
      throw PermissionDeniedException();
    }

    int? socks;
    int? http;
    if (!isTunnel) {
      socks = _inboundPort(config, protocol: 'socks');
      http = _inboundPort(config, protocol: 'http');
      if (socks == null) {
        // Not a validator — a hard requirement of the hev bridge: without a
        // known SOCKS port there is literally nothing to bridge into.
        throw ArgumentError(
          'connectViaConfig: no tun inbound in the config, so systemProxy '
          'mode is used — but no socks inbound with an explicit port was found',
        );
      }
    }

    return _startWithConfig(
      config: config,
      coreName: selectedCore.name,
      isTunnel: isTunnel,
      socksPort: socks,
      httpPort: http,
      body: isTunnel ? 'TUN (custom config)' : 'SOCKS5 (custom config)',
    );
  }

  Future<bool> _startWithConfig({
    required Map<String, dynamic> config,
    required String coreName,
    required bool isTunnel,
    required int? socksPort,
    required int? httpPort,
    required String body,
  }) async {
    _activeMode = isTunnel ? ConnectionMode.tunnel : ConnectionMode.systemProxy;
    _socksPort = socksPort;
    _httpPort = httpPort;

    final bool? started = await _methodChannel.invokeMethod<bool>('startVpn', {
      'core': coreName,
      'mode': isTunnel ? 'tunnel' : 'systemProxy',
      'socksPort': isTunnel ? 0 : (socksPort ?? 0),
      'config': jsonEncode(config),
      'tunParams': _tunParams(isTunnel),
      'notificationTitle': isTunnel ? 'VPN Connected' : 'Proxy Tunnel',
      'notificationBody': body,
    });

    if (started != true) {
      _activeMode = null;
      _socksPort = null;
      _httpPort = null;
      return false;
    }

    final alive = await _waitForCore();
    if (!alive) {
      await _methodChannel.invokeMethod('stopVpn');
      _activeMode = null;
      _socksPort = null;
      _httpPort = null;
    }
    return alive;
  }

  static bool _hasTunInbound(Map<String, dynamic> config) {
    final inbounds = config['inbounds'];
    if (inbounds is! List) return false;
    return inbounds.any(
      (raw) =>
          raw is Map && (raw['protocol'] ?? raw['type'])?.toString() == 'tun',
    );
  }

  static int? _inboundPort(
    Map<String, dynamic> config, {
    required String protocol,
  }) {
    final inbounds = config['inbounds'];
    if (inbounds is! List) return null;
    for (final raw in inbounds) {
      if (raw is! Map) continue;
      if ((raw['protocol'] ?? raw['type'])?.toString() != protocol) continue;
      final p = raw['port'] ?? raw['listen_port'];
      if (p is int) return p;
      if (p is String) return int.tryParse(p);
    }
    return null;
  }
}
