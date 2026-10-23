part of 'core_config_builder.dart';

final class SingboxConfigBuilder extends VpnCoreConfigBuilder {
  @override
  VpnCore get core => VpnCore.singbox;

  final bool isDesktop;
  final bool isAutoRoute;
  final int? fileDescriptor;

  /// Clash API external controller. `<= 0` omits the whole `experimental`
  /// block: a fixed 9090 makes startup fail outright whenever the port is
  /// already taken (leftover session, another app), and sing-box rejects the
  /// config instead of degrading gracefully.
  final int clashApiPort;
  final String clashApiSecret;
  final String inboundTag;

  /// Emit a tun inbound. `false` = tun2socks (hev) mode: the core only
  /// exposes a loopback SOCKS5 listener and libbox never calls openTun().
  final bool hasTunInbound;

  /// Loopback SOCKS5 port, used when [hasTunInbound] is false.
  final int socksPort;

  /// Resolve user DNS over DoH **through the tunnel** instead of forwarding
  /// raw UDP/53. Off by default to keep desktop behaviour untouched.
  final bool tunnelDns;

  /// Reject UDP/443 (QUIC / HTTP3).
  final bool blockQuic;

  /// DNS answer strategy.
  ///
  /// `prefer_ipv4` STILL RETURNS AAAA when the client asks - and browsers ask
  /// A and AAAA in parallel. Combined with the "::/0" route that a TUN
  /// inbound installs, that makes the browser try IPv6 first; if the rule
  /// sends it to the `direct` outbound and the phone has no native IPv6, the
  /// connection blackholes (RU sites "just do not open").
  /// Use `ipv4_only` whenever direct-routed traffic is possible.
  final String dnsStrategy;

  /// Resolver for domains that routing sends `direct` (split DNS).
  /// null = reuse [bootstrapDnsTag] (plain UDP, no detour).
  /// Set e.g. "https://common.dot.dns.yandex.net/dns-query" for RU.
  final String? directDnsServer;

  /// Auto-derive split DNS from the routing preset: every `direct` rule that
  /// carries domain criteria also gets resolved by a direct resolver.
  final bool splitDnsForDirect;

  SingboxConfigBuilder({
    required this.isDesktop,
    this.isAutoRoute = true, // Android via libbox/openTun expects true (SFA parity)
    this.fileDescriptor,
    this.clashApiPort = 9090,
    this.clashApiSecret = '',
    this.inboundTag = 'tun-in',
    this.hasTunInbound = true,
    this.socksPort = 10808,
    this.tunnelDns = false,
    this.blockQuic = false,
    this.dnsStrategy = 'prefer_ipv4',
    this.directDnsServer,
    this.splitDnsForDirect = true,
  });

  static const String bootstrapDnsTag = 'bootstrap-dns';
  static const String remoteDnsTag = 'remote-dns';
  static const String directDnsTag = 'direct-dns';

  static final _ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
  static final _ipv6 = RegExp(r'^[0-9a-fA-F:]+$');
  bool _isIpLiteral(String h) =>
      _ipv4.hasMatch(h) || (h.contains(':') && _ipv6.hasMatch(h));

  /// First usable IP-literal bootstrap server.
  ///
  /// MUST be an IP and MUST have no `detour`: it is the only resolver that
  /// can break the "resolve the proxy server -> need the proxy -> resolve
  /// the proxy server" cycle. `"type": "local"` cannot do that on Android -
  /// it goes Bionic -> netd -> UDP/53 -> straight back into our own TUN.
  String _bootstrapServer(TunConfig tun) {
    for (final raw in (tun.customDnsServers??[])) {
      final host = raw.contains('://') ? Uri.parse(raw).host : raw.trim();
      if (_isIpLiteral(host)) return host;
    }
    return '1.1.1.1';
  }

  @override
  Map<String, dynamic> buildConfig({
    required List<VpnNodeData> nodes,
    required OutboundGroup? activeGroup,
    required List<RoutingRule> customRules,
    required TunConfig tunConfig,
  }) {
    final defaultProxyTag = activeGroup?.tag ??
        (nodes.isNotEmpty ? nodes.first.name : 'proxy');

    return {
      "log": {"level": "warn", "timestamp": true},
      if (clashApiPort > 0)
        "experimental": {
          "clash_api": {
            "external_controller": "127.0.0.1:$clashApiPort",
            "secret": clashApiSecret,
          }
        },
      "dns": _buildDns(tunConfig, defaultProxyTag, customRules),
      "inbounds": [
        _buildInbound(tunConfig: tunConfig),
      ],
      "outbounds": _buildOutbounds(nodes, activeGroup),
      "route": _buildRoute(tunConfig, customRules, defaultProxyTag, nodes),
    };
  }
  Map<String, dynamic> _buildRoute(
    TunConfig tun,
    List<RoutingRule> customRules,
    String defaultProxyTag,
    List<VpnNodeData> nodes,
  ) {
    // RULE ORDER IS SEMANTIC. Do not reorder blindly.
    final rules = <Map<String, dynamic>>[
      if (tun.enableSniffing)
        {"inbound": [inboundTag], "action": "sniff", "timeout": "300ms"},

      // 1.11+ : hijack-dns ACTION replaces the "dns" outbound.
      // It is bound to the tun inbound (inbound.tun.dns_mode: hijack) -
      // emitting it without a tun inbound makes sing-box REJECT the config,
      // which is the "endless connecting" symptom.
      if (hasTunInbound && tun.enableDnsHijacking)
        {"protocol": "dns", "action": "hijack-dns"},

      // QUIC kill-switch. Lives in the builder: it must run before the LAN and
      // preset rules.
      if (blockQuic) {"network": "udp", "port": 443, "action": "reject"},

      // LAN bypass MUST precede the port-53 rule, otherwise a query to the
      // home router (192.168.1.1:53) gets proxied instead of going direct.
      if (tun.bypassLan) {"ip_is_private": true, "outbound": "direct"},

      // No tun => nothing hijacks DNS, so forward port 53 through the tunnel
      // explicitly (leak-free) instead of relying on `final`.
      if (!hasTunInbound) {"port": 53, "outbound": defaultProxyTag},
    ];

    // User/built-in presets. projectSingboxRules validates every emitted rule
    // against the sing-box key allow-list and throws naming the offending rule,
    // instead of letting the core fail with "json: unknown field" after a
    // 12 s silent hang.
    final projection = projectSingboxRules(
      customRules,
      proxyTag: defaultProxyTag,
      nodes: nodes,
    );
    _lastProjection = projection;
    rules.addAll(projection.rules);

    return {
      "rules": rules,

      // MANDATORY. Without route.final sing-box sends every unmatched
      // connection to "direct", i.e. silently bypasses the proxy.
      "final": defaultProxyTag,

      // 1.12+ : resolver for the PROXY SERVER's own address.
      // Always the detour-less bootstrap server, otherwise resolving the node
      // requires the tunnel that this very resolution is needed for.
      "default_domain_resolver": {
        "server": bootstrapDnsTag,
        "strategy": "prefer_ipv4",
      },
      "auto_detect_interface": true,
    };
  }

  Map<String, dynamic> _buildInbound({required TunConfig tunConfig}) {
    if (!hasTunInbound) {
      // tun2socks mode: hev owns the TUN fd, sing-box only serves SOCKS5.
      //
      // NOTE: there is NO "udp" field on a sing-box socks inbound (that is an
      // Xray option). sing-box decodes configs strictly and aborts with
      // `inbound options: json: unknown field "udp"`. SOCKS5 UDP ASSOCIATE is
      // always supported here, which is what hev needs for DNS and datagrams.
      return {
        "type": "socks",
        "tag": inboundTag,
        "listen": "127.0.0.1",
        "listen_port": socksPort,
        // ListenOptions field (valid since 1.12): idle UDP sessions from the
        // bridge are reaped instead of hanging forever.
        "udp_timeout": "5m",
      };
    }

    return {
      "type": "tun",
      "tag": inboundTag,
      "interface_name": isDesktop ? "wintun" : "tun0",
      "mtu": tunConfig.mtu,
      "stack": tunConfig.stack.name,
      // 1.12+ : single "address" list replaces inet4_address / inet6_address
      "address": [
        tunConfig.inet4Address,
        if (tunConfig.inet6Address.isNotEmpty) tunConfig.inet6Address,
      ],
      "auto_route": isAutoRoute,
      "strict_route": tunConfig.strictRoute,
      if (fileDescriptor != null) "file_descriptor": fileDescriptor,
    };
  }

  /// sing-box 1.12+ typed DNS.
  ///
  /// Three tiers, all always present:
  ///  - [bootstrapDnsTag]: plain UDP, NO detour. Breaks the "resolve the proxy
  ///    server -> need the proxy" cycle and resolves the node's own hostname.
  ///  - [directDnsTag]: resolver for domains the routing preset sends
  ///    `direct`. Without it those domains are answered from the EXIT server
  ///    ("resolve abroad, connect locally"), which RU banks/gov/CDN often
  ///    reject. This is the sing-box counterpart of the provider's
  ///    `common.dot.dns.yandex.net` + `domains:[regexp:.*\.ru$]`.
  ///  - [remoteDnsTag]: DoH through the tunnel for everything else.
  Map<String, dynamic> _buildDns(
    TunConfig tun,
    String proxyTag,
    List<RoutingRule> customRules,
  ) {
    final bootstrap = _bootstrapServer(tun);
    final custom = tun.customDnsServers ?? const <String>[];
    final primaryRaw = custom.isNotEmpty ? custom.first : '1.1.1.1';

    final directCriteria =
        splitDnsForDirect ? _directDomainCriteria(customRules) : const <Map<String, dynamic>>[];
    final hasDirectSplit = directCriteria.isNotEmpty;

    if (!tunnelDns) {
      return {
        "servers": [
          _dnsServerEntry(primaryRaw, remoteDnsTag, detour: proxyTag),
          {"tag": "local-dns", "type": "local"},
          {"tag": bootstrapDnsTag, "type": "udp", "server": bootstrap},
          if (hasDirectSplit)
            _dnsServerEntry(directDnsServer ?? bootstrap, directDnsTag),
        ],
        if (hasDirectSplit)
          "rules": [
            for (final criteria in directCriteria)
              {...criteria, "server": directDnsTag},
          ],
        "final": remoteDnsTag,
        "strategy": dnsStrategy,
      };
    }

    return {
      "servers": [
        // Bootstrap first: no detour, IP literal, always reachable.
        {"tag": bootstrapDnsTag, "type": "udp", "server": bootstrap},
        if (hasDirectSplit)
          _dnsServerEntry(directDnsServer ?? bootstrap, directDnsTag),
        {
          "tag": remoteDnsTag,
          "type": "https",
          "server": "one.one.one.one",
          "path": "/dns-query",
          "detour": proxyTag,
          // 1.12+ requires an explicit resolver for domain-based servers.
          "domain_resolver": bootstrapDnsTag,
        },
        {
          "tag": "remote-dns-2",
          "type": "https",
          "server": "dns.google",
          "path": "/dns-query",
          "detour": proxyTag,
          "domain_resolver": bootstrapDnsTag,
        },
      ],
      if (hasDirectSplit)
        "rules": [
          for (final criteria in directCriteria)
            {...criteria, "server": directDnsTag},
        ],
      "final": remoteDnsTag,
      "strategy": dnsStrategy,
    };
  }

  /// Domain criteria of every `direct` routing rule, as sing-box DNS-rule
  /// fields. IP criteria are skipped on purpose: in a DNS rule `ip_cidr`
  /// matches the ANSWER, not the query, which is not what we want here.
  List<Map<String, dynamic>> _directDomainCriteria(List<RoutingRule> rules) {
    final out = <Map<String, dynamic>>[];

    for (final rule in rules) {
      if (!rule.enabled) continue;
      if (rule.action != RoutingAction.direct) continue;
      if (rule.domains.isEmpty) continue;

      final key = switch (rule.domainType) {
        RuleDomainMatchType.suffix => 'domain_suffix',
        RuleDomainMatchType.exact => 'domain',
        RuleDomainMatchType.keyword => 'domain_keyword',
        RuleDomainMatchType.regex => 'domain_regex',
      };

      out.add({key: rule.domains});
    }

    return out;
  }
  
  Map<String, dynamic> _dnsServerEntry(String raw, String tag,
      {String? detour}) {
    final d = raw.trim();
    final Map<String, dynamic> entry;

    if (d == 'local') {
      // "local" is unusable on Android (no /etc/resolv.conf wiring, and the
      // 127.0.0.1:53 fallback re-enters our own TUN). Degrade to UDP.
      entry = {"type": "udp", "server": "1.1.1.1"};
    } else if (d.startsWith('rcode://')) {
      entry = {"type": "rcode", "rcode": d.substring('rcode://'.length)};
    } else if (d.contains('://')) {
      final uri = Uri.parse(d);
      final host = uri.host;
      entry = switch (uri.scheme) {
        'https' => {
            "type": "https",
            "server": host,
            if (uri.path.isNotEmpty && uri.path != '/') "path": uri.path,
          },
        'h3' => {"type": "h3", "server": host},
        'quic' => {"type": "quic", "server": host},
        'tls' => {"type": "tls", "server": host},
        'tcp' => {"type": "tcp", "server": host},
        _ => {"type": "udp", "server": d},
      };
      // 1.12+ requires an explicit resolver for domain-based servers
      if (!_isIpLiteral(host)) entry["domain_resolver"] = bootstrapDnsTag;
    } else {
      entry = {"type": "udp", "server": d};
    }

    entry["tag"] = tag;
    if (detour != null) entry["detour"] = detour;
    return entry;
  }

  List<Map<String, dynamic>> _buildOutbounds(
      List<VpnNodeData> nodes, OutboundGroup? activeGroup) {
    final List<Map<String, dynamic>> outbounds = [];

    if (activeGroup != null) {
      final isSelector = activeGroup.type == OutboundGroupType.selector;
      final outboundsList = activeGroup.outboundTags.isNotEmpty
          ? activeGroup.outboundTags
          : nodes.map((e) => e.name).toList();

      outbounds.add({
        "type": isSelector ? "selector" : "urltest",
        "tag": activeGroup.tag,
        "outbounds": outboundsList,
        if (isSelector && outboundsList.isNotEmpty)
          "default": outboundsList.first,
        if (!isSelector) ...{
          "url": activeGroup.testUrl.isNotEmpty
              ? activeGroup.testUrl
              : "https://www.gstatic.com/generate_204",
          "interval": "${activeGroup.interval.inSeconds}s",
          "tolerance": activeGroup.tolerance.inMilliseconds,
        }
      });
    }

    for (final node in nodes) {
      outbounds.add(_buildSingleNodeOutbound(node));
    }

    // NOTE: "block" and "dns" outbounds were REMOVED in 1.11+.
    outbounds.add({"type": "direct", "tag": "direct"});

    return outbounds;
  }

  Map<String, dynamic> _buildSingleNodeOutbound(VpnNodeData node) {
    final proto = node.protocol;
    final p = node.params;
    final isTls = p['security'] == 'tls' || p['security'] == 'reality';
    final isReality = p['security'] == 'reality';

    final Map<String, dynamic> outbound = {
      "type": proto.name,
      "tag": node.name,
      "server": node.address,
      "server_port": node.port,
    };

    // Общие TLS / Reality параметры
    Map<String, dynamic>? tlsBlock;
    if (isTls) {
      tlsBlock = {
        "enabled": true,
        "server_name": p['sni'] ?? node.address,
        "insecure": p['allowInsecure'] == '1' || p['insecure'] == 'true',
        if (p['alpn'] != null) "alpn": p['alpn']!.split(','),
        if (p['fp'] != null)
          "utls": {
            "enabled": true,
            "fingerprint": p['fp']!,
          },
        if (isReality)
          "reality": {
            "enabled": true,
            "public_key": p['pbk'] ?? '',
            "short_id": p['sid'] ?? '',
          }
      };
    }

    // Транспортные протоколы (WS, gRPC, HTTP, HTTPUpgrade)
    Map<String, dynamic>? transportBlock;
    final netType = p['type'] ?? p['net'] ?? 'tcp';
    if (netType == 'ws') {
      transportBlock = {
        "type": "ws",
        "path": p['path'] ?? "/",
        "headers": {
          if (p['host'] != null) "Host": p['host']!,
        }
      };
    } else if (netType == 'grpc') {
      transportBlock = {
        "type": "grpc",
        "service_name": p['serviceName'] ?? p['path'] ?? "",
      };
    } else if (netType == 'h2' || netType == 'http') {
      transportBlock = {
        "type": "http",
        "host": p['host'] != null ? [p['host']!] : [node.address],
        "path": p['path'] ?? "/",
      };
    } else if (netType == 'httpupgrade') {
      transportBlock = {
        "type": "httpupgrade",
        "path": p['path'] ?? "/",
        "host": p['host'] ?? node.address,
      };
    }

    switch (proto) {
      case ProtocolTypes.vless:
        outbound['uuid'] = node.credential;
        if (p['flow'] != null && p['flow']!.isNotEmpty) {
          outbound['flow'] = p['flow'];
        }
        if (tlsBlock != null) outbound['tls'] = tlsBlock;
        if (transportBlock != null) outbound['transport'] = transportBlock;

      case ProtocolTypes.vmess:
        outbound['uuid'] = node.credential;
        outbound['security'] = p['scy'] ?? 'auto';
        outbound['alter_id'] = int.tryParse(p['aid'] ?? '0') ?? 0;
        if (tlsBlock != null) outbound['tls'] = tlsBlock;
        if (transportBlock != null) outbound['transport'] = transportBlock;

      case ProtocolTypes.trojan:
        outbound['password'] = node.credential;
        if (tlsBlock != null) outbound['tls'] = tlsBlock;
        if (transportBlock != null) outbound['transport'] = transportBlock;

      case ProtocolTypes.shadowsocks:
        outbound['method'] = p['method'] ?? 'chacha20-ietf-poly1305';
        outbound['password'] = node.credential;
        if (p['plugin'] != null) {
          outbound['plugin'] = p['plugin'];
          outbound['plugin_opts'] = p['plugin_opts'];
        }

      case ProtocolTypes.wireguard:
        outbound.remove('server');
        outbound.remove('server_port');
        outbound['type'] = 'wireguard';
        outbound['server'] = node.address;
        outbound['server_port'] = node.port;
        outbound['system_interface'] = false;
        outbound['private_key'] = node.credential;
        outbound['peer_public_key'] =
            p['peer_public_key'] ?? p['public_key'] ?? '';
        outbound['local_address'] =
            (p['local_address'] ?? '10.0.0.2/32').split(',');
        if (p['preshared_key'] != null) {
          outbound['pre_shared_key'] = p['preshared_key'];
        }
        if (p['reserved'] != null) {
          outbound['reserved'] = p['reserved']!.split(',').map(int.parse).toList();
        }
        if (p['mtu'] != null) outbound['mtu'] = int.tryParse(p['mtu']!);

      case ProtocolTypes.hysteria2:
        outbound['password'] = node.credential;
        if (tlsBlock != null) outbound['tls'] = tlsBlock;
        if (p['obfs'] != null) {
          outbound['obfs'] = {
            "type": p['obfs'],
            "password": p['obfs-password'] ?? "",
          };
        }
        if (p['up'] != null) outbound['up_mbps'] = int.tryParse(p['up']!);
        if (p['down'] != null) outbound['down_mbps'] = int.tryParse(p['down']!);

      case ProtocolTypes.tuic:
        outbound['uuid'] = node.credential;
        outbound['password'] = p['password'] ?? '';
        outbound['congestion_control'] = p['congestion_control'] ?? 'bbr';
        outbound['udp_relay_mode'] = p['udp_relay_mode'] ?? 'native';
        if (tlsBlock != null) outbound['tls'] = tlsBlock;

      case ProtocolTypes.ssh:
        outbound['user'] = p['user'] ?? 'root';
        outbound['password'] = node.credential;
        if (p['public_key'] != null) {
          outbound['public_key'] = [p['public_key']!];
        }

      default:
        throw UnsupportedProtocolException(
            providedProtocolType: proto,
            sellectedVpnCore: core,
            supportStatus: ProtocolSupportStatus.unsupported);
    }

    return outbound;
  }
}