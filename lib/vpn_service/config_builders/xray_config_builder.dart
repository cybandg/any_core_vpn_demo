part of 'core_config_builder.dart';

/// Private / loopback / link-local / CGNAT ranges.
/// Explicit CIDRs on purpose: no geoip.dat dependency.
const List<String> kXrayPrivateCidrs = <String>[
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '127.0.0.0/8',
  '169.254.0.0/16',
  '100.64.0.0/10', // CGNAT (mobile carriers)
  '224.0.0.0/4', // multicast
  'fe80::/10',
  'fc00::/7',
  'ff00::/8',
];

/// Curated RU-resident services. Suffix match ("domain:" semantics).
/// Edit freely: this is data, not logic.
const List<String> kXrayRuResidentDomains = <String>[
  // Yandex
  'yandex.ru', 'yandex.net', 'yandex.com', 'ya.ru', 'yastatic.net',
  'yandexcloud.net', 'kinopoisk.ru', 'auto.ru', 'beru.ru', 'edadeal.ru',
  // VK / Mail.ru
  'vk.com', 'vk.ru', 'vk.me', 'vkontakte.ru', 'vkuseraudio.com', 'vkvideo.ru',
  'mail.ru', 'list.ru', 'inbox.ru', 'bk.ru', 'internet.ru',
  'ok.ru', 'mytarget.ru', 'dmp.wi-fi.ru', 'delivery-club.ru',
  // Gov / taxes
  'gosuslugi.ru', 'nalog.ru', 'nalog.gov.ru', 'mos.ru', 'cbr.ru', 'mir.ru',
  'nspk.ru', 'zakupki.gov.ru', 'sudact.ru', 'kad.arbitr.ru',
  // Banks
  'sberbank.ru', 'sbol.ru', 'sberbank.com', 'sber.ru', 'sberdevices.ru',
  'tinkoff.ru', 'tbank.ru', 'alfabank.ru', 'vtb.ru', 'gazprombank.ru',
  'raiffeisen.ru', 'open.ru', 'mkb.ru', 'pochtabank.ru', 'domclick.ru',
  'sberbank-tele.com', 'mpsbol.ru',
  // Telecom
  'mts.ru', 'megafon.ru', 'beeline.ru', 'tele2.ru', 'rt.ru', 'dom.ru',
  'rostelecom.ru', 'er-telecom.ru', 'ertelecom.ru', 'motivllc.ru',
  'wifire.ru', 'tinkoffmobile.ru',
  // Retail
  'avito.ru', 'avito.st', 'ozon.ru', 'wildberries.ru', 'wb.ru', 'lamoda.ru',
  'citilink.ru', 'dns-shop.ru', 'mvideo.ru', 'eldorado.ru', 'sportmaster.ru',
  'pyaterochka.ru', 'magnit.ru', 'magnit.info', 'x5.ru', 'kuper.ru',
  'samokat.ru', 'vkusvill.ru', 'perekrestok.ru', 'lenta.com', 'auchan.ru',
  'detmir.ru', 'detsky.ru', 're-store.ru', 'sitetools.ru',
  // Media / services
  'rbc.ru', 'lenta.ru', 'gazeta.ru', 'ria.ru', 'tass.ru', 'kommersant.ru',
  'vedomosti.ru', '1tv.ru', 'ntv.ru', 'tvc.ru', 'ren.tv', 'smotrim.ru',
  'rutube.ru', 'pikabu.ru', 'habr.com', '4pda.to', 'drom.ru', 'drive2.ru',
  'hh.ru', 'superjob.ru', 'cian.ru', '2gis.ru', '2gis.com', 'max.ru',
  'rambler.ru', 'championat.com', 'sports.ru', 'livejournal.com',
  'rzd.ru', 'tutu.ru', 'poezdrf.ru', 'sapsan.rzd.ru', 'gosuslugi.com',
];

/// mDNS / LAN name suffixes.
const List<String> kXrayPrivateDomains = <String>[
  'domain:local',
  'domain:lan',
  'domain:home',
  'domain:internal',
  'domain:localdomain',
  'domain:intranet',
  'domain:corp',
];

/// A DoH resolver reachable without any bootstrap DNS:
/// the hostname is pinned in `dns.hosts`, and the pinned IPs are forced
/// through the tunnel by a routing rule.
class _DohResolver {
  const _DohResolver({
    required this.host,
    required this.ips,
    required this.url,
    required this.domainRules,
    required this.domains,
  });

  final String host;
  final List<String> ips;
  final String url;
  final List<String> domainRules;
  final List<String> domains;
}

const List<_DohResolver> _kDefaultDohResolvers = <_DohResolver>[
  _DohResolver(
    host: 'one.one.one.one',
    ips: <String>['1.1.1.1', '1.0.0.1'],
    url: 'https://one.one.one.one/dns-query',
    domainRules: <String>['domain:one.one'],
    domains: <String>[],
  ),
  _DohResolver(
    host: 'dns.google',
    ips: <String>['8.8.8.8', '8.8.4.4'],
    url: 'https://dns.google/dns-query',
    domainRules: <String>['domain:dns.google', 'domain:googleapis.com'],
    domains: <String>[],
  ),
];

final class XrayConfigBuilder extends VpnCoreConfigBuilder {
  @override
  VpnCore get core => VpnCore.xray;

  final int socksPort;
  final int httpPort;
  final String listenAddress;

  final String inboundTag;
  final String httpInboundTag;
  final List<String> sniffDestOverride;

  /// Balancer health probe. leastPing/leastLoad REQUIRE an observatory:
  /// outbounds with no observation data are excluded outright, so a
  /// multi-node config without a working probe silently collapses onto
  /// outbounds[0].
  /// Only ONE of observatory/burstObservatory may exist (both register the
  /// same global extension.Observatory) - we always emit the burst variant.
  final bool enableHealthProbe;
  final String probeDestination;

  /// Local-network sanity URL, probed only when [probeDestination] fails.
  /// Lets the log distinguish "node is dead" from "my Wi-Fi is dead".
  final String probeConnectivity;

  final Duration probeInterval;
  final int probeSampling;
  final Duration probeTimeout;

  /// Outbound used when every probed node is down.
  final String? balancerFallbackTag;

  /// When several nodes are supplied without an explicit OutboundGroup they
  /// are wrapped into an internal leastPing balancer instead of leaving the
  /// chain pinned to a single exit. Mirrors the provider's ENTRY-PROXY.
  final bool autoBalanceMultipleNodes;
  final String autoBalancerTag;

  /// Emit the tun inbound. Set to `false` for the tun2socks (hev) mode:
  /// the core then only exposes loopback SOCKS5/HTTP listeners and never
  /// touches the TUN descriptor.
  final bool enableTunInbound;

  /// Resolve DNS inside Xray over DoH **through the tunnel**.
  /// When false the old behaviour is kept: plain UDP/53 resolvers, which
  /// leak every queried domain to the ISP in clear text.
  final bool tunnelDns;

  /// Kill UDP/443 (QUIC / HTTP3). Without it browsers keep trying HTTP3,
  /// those datagrams crawl through SOCKS5 UDP ASSOCIATE and time out,
  /// which both slows pages down and pollutes the tunnel profile.
  final bool blockQuic;

  /// Send `.ru` / `.xn--p1ai` and [kXrayRuResidentDomains] straight out
  /// (freedom), bypassing the tunnel.
  final bool ruTrafficDirect;

  /// Extra domains forced direct on top of [ruTrafficDirect].
  final List<String> extraDirectDomains;

  /// AsIs | IPIfNonMatch | IPOnDemand.
  /// IPIfNonMatch is required for the IP-based rules (private ranges,
  /// pinned DoH IPs) to match domain destinations.
  final String routingDomainStrategy;

  final String dnsQueryStrategy;

  /// true = sniffed domain is used for routing only, the original IP is
  /// dialed. false = the sniffed domain replaces the destination (provider
  /// behaviour, causes one extra cached DoH lookup).
  final bool sniffRouteOnly;

  /// LAN resolver used ONLY for mDNS-style private names.
  /// Never use "localhost" here: Android has no /etc/resolv.conf, Go's
  /// resolver falls back to 127.0.0.1:53 which loops straight back into
  /// our own TUN.
  final String? localDnsServer;

  final String? directDnsServer;

  final bool splitDnsForDirect;

  XrayConfigBuilder({
    this.socksPort = 10808,
    this.httpPort = 10809,
    this.listenAddress = "127.0.0.1",
    this.inboundTag = "socks-in",
    this.httpInboundTag = "http-in",
    this.sniffDestOverride = const ["http", "tls", "quic"],
    this.enableTunInbound = true,
    this.tunnelDns = true,
    this.blockQuic = true,
    this.ruTrafficDirect = false,
    this.extraDirectDomains = const [],
    this.routingDomainStrategy = "IPIfNonMatch",
    this.dnsQueryStrategy = "UseIPv4",
    this.sniffRouteOnly = false,
    this.localDnsServer,
    this.enableHealthProbe = true,
    this.probeDestination =
        "https://connectivitycheck.gstatic.com/generate_204",
    this.probeConnectivity = "",
    this.probeInterval = const Duration(minutes: 3),
    this.probeSampling = 3,
    this.probeTimeout = const Duration(seconds: 3),
    this.balancerFallbackTag,
    this.autoBalanceMultipleNodes = true,
    this.autoBalancerTag = "ENTRY-PROXY",
    this.directDnsServer,
    this.splitDnsForDirect = true,
  });

  static const String tunInboundTag = "tun-in";

  /// Defensive normalisation: a caller may still pass "tun-in" here (older
  /// call sites did), which would duplicate the tun inbound tag.
  String get _socksTag => inboundTag == tunInboundTag ? "socks-in" : inboundTag;

  @override
  Map<String, dynamic> buildConfig({
    required List<VpnNodeData> nodes,
    required OutboundGroup? activeGroup,
    required List<RoutingRule> customRules,
    required TunConfig tunConfig,
  }) {
    final inbounds = <Map<String, dynamic>>[
      // The TUN inbound (when present) MUST stay first: it carries device
      // traffic and its fd is injected natively.
      if (enableTunInbound) _buildTunInbound(tunConfig),
      _buildSocksInbound(tunConfig),
      _buildHttpInbound(tunConfig),
    ];

    // Tags must be unique across the whole inbound list.
    final tags = inbounds.map((e) => e["tag"] as String).toSet();
    if (tags.length != inbounds.length) {
      throw StateError(
        'XrayConfigBuilder produced duplicate inbound tags: '
        '${inbounds.map((e) => e["tag"]).toList()}',
      );
    }

    final useBalancer = _usesBalancer(activeGroup, nodes);

    return {
      // access/error logs are injected natively at start time (real paths).
      "log": {"loglevel": "warning"},
      "dns": _buildDns(tunConfig, customRules),
      "inbounds": inbounds,
      "outbounds": _buildOutbounds(nodes),
      // leastPing has no data source without this block -> every node would
      // be treated as "not observed" and excluded by the balancer.
      if (useBalancer && enableHealthProbe)
        "burstObservatory": _buildBurstObservatory(activeGroup, nodes),
      "routing": _buildRouting(tunConfig, customRules, activeGroup, nodes),
    };
  }

  /// A balancer is used either because an explicit non-selector group was
  /// requested, or because several nodes arrived and auto-balancing is on.
  bool _usesBalancer(OutboundGroup? group, List<VpnNodeData> nodes) {
    if (group != null) return group.type != OutboundGroupType.selector;
    return autoBalanceMultipleNodes && nodes.length > 1;
  }

  List<String> _selector(OutboundGroup? group, List<VpnNodeData> nodes) {
    if (group != null && group.outboundTags.isNotEmpty) {
      return group.outboundTags;
    }
    return nodes.map((e) => e.name).toList();
  }

  String _balancerTag(OutboundGroup? group) => group?.tag ?? autoBalancerTag;

  /// burstObservatory. `sampling` probes are spread RANDOMLY over
  /// interval*sampling, which is exactly why the provider prefers it:
  /// a fixed-period probe is itself a recognisable fingerprint.
  Map<String, dynamic> _buildBurstObservatory(
    OutboundGroup? group,
    List<VpnNodeData> nodes,
  ) {
    return {
      "subjectSelector": _selector(group, nodes),
      "pingConfig": {
        "timeout": "${probeTimeout.inSeconds}s",
        "interval": "${probeInterval.inSeconds}s",
        "sampling": probeSampling,
        "httpMethod": "HEAD",
        "destination": probeDestination,
        if (probeConnectivity.isNotEmpty) "connectivity": probeConnectivity,
      },
    };
  }

  // ---------------- inbounds ----------------

  /// TUN inbound. Settings intentionally minimal:
  ///  - "name" is injected NATIVELY (must skip Xray's interface enumeration —
  ///    netlink is forbidden to Android apps).
  ///  - "mtu" is re-forced natively to match the VpnService builder.
  ///  - NO autoRoute/autoDetectInterface/autoOutboundsInterface: not Xray
  ///    fields, or netlink-forbidden on Android.
  /// The fd is delivered via config root env["xray.tun.fd"] (native side).
  Map<String, dynamic> _buildTunInbound(TunConfig tun) {
    return {
      "tag": "tun-in",
      "port": 0,
      "protocol": "tun",
      "settings": {"mtu": tun.mtu},
      "sniffing": _sniffing(tun),
    };
  }

  /// SOCKS5 inbound. `udp: true` is MANDATORY for the tun2socks bridge:
  /// hev relays DNS and every datagram through SOCKS5 UDP ASSOCIATE.
  Map<String, dynamic> _buildSocksInbound(TunConfig tun) {
    return {
      "tag": _socksTag,
      "port": socksPort,
      "listen": listenAddress,
      "protocol": "socks",
      "settings": {"auth": "noauth", "udp": true},
      "sniffing": _sniffing(tun),
    };
  }

  Map<String, dynamic> _buildHttpInbound(TunConfig tun) {
    return {
      "tag": httpInboundTag,
      "port": httpPort,
      "listen": listenAddress,
      "protocol": "http",
      "settings": {"allowTransparent": false},
      "sniffing": _sniffing(tun),
    };
  }

  /// Sniffing is what makes domain rules work at all behind hev: the bridge
  /// hands Xray raw IPs, the domain is recovered from TLS SNI / HTTP Host.
  Map<String, dynamic> _sniffing(TunConfig tun) {
    return {
      "enabled": tun.enableSniffing,
      "routeOnly": sniffRouteOnly,
      "destOverride": sniffDestOverride,
    };
  }

  // ---------------- dns ----------------

  /// DNS is resolved INSIDE Xray over DoH, and the DoH connections are forced
  /// through the tunnel by routing rules, so the ISP never sees a query.
  ///
  /// Split DNS: domains the routing preset sends `direct` are resolved by
  /// [directDnsServer] WITHOUT the tunnel. Otherwise they are answered from
  /// the exit server and then dialed from the local IP ("resolve abroad,
  /// connect locally"), which RU banks / gov / CDN frequently reject.
  Map<String, dynamic> _buildDns(TunConfig tun, List<RoutingRule> customRules) {
    if (!tunnelDns) {
      return {
        "servers":
            (tun.customDnsServers == null || tun.customDnsServers!.isEmpty)
            ? ["1.1.1.1", "8.8.8.8"]
            : tun.customDnsServers,
        "queryStrategy": dnsQueryStrategy,
      };
    }

    final hosts = <String, dynamic>{};
    final servers = <Map<String, dynamic>>[];

    // Private/LAN names must never be sent to a public DoH resolver.
    final local = localDnsServer;
    if (local != null && local.isNotEmpty) {
      servers.add({
        "address": local,
        "domains": kXrayPrivateDomains,
        "expectIPs": kXrayPrivateDomains,
        "skipFallback": true,
      });
    }

    // Split DNS for direct-routed domains. Must precede the tunnelled
    // resolvers: Xray picks the first server whose `domains` match.
    final directDomains = splitDnsForDirect
        ? _directDomainCriteriaXray(customRules)
        : const <String>[];
    if (directDnsServer != null && directDomains.isNotEmpty) {
      servers.add({
        "address": directDnsServer,
        "domains": directDomains,
        // Do not let a failure here fall through to the tunnelled resolvers,
        // that would silently reintroduce the "resolve abroad" problem.
        "skipFallback": true,
      });
    }

    for (final resolver in _kDefaultDohResolvers) {
      hosts[resolver.host] = resolver.ips;
      servers.add({
        "address": resolver.url,
        if (resolver.domains.isNotEmpty) "domains": resolver.domains,
      });
    }

    return {
      // Pin the DoH hostnames so resolving them needs no bootstrap DNS.
      "hosts": hosts,
      "servers": servers,
      // UseIPv4 is load-bearing: with AAAA answers present AND a "::/0" route
      // installed by the TUN, browsers try IPv6 first; a direct-routed IPv6
      // connection on a phone without native IPv6 blackholes.
      "queryStrategy": dnsQueryStrategy,
      "disableCache": false,
      "disableFallback": false,
    };
  }

  /// Xray `dns.servers[].domains` entries for every `direct` routing rule.
  List<String> _directDomainCriteriaXray(List<RoutingRule> rules) {
    final out = <String>[];
    for (final rule in rules) {
      if (!rule.enabled) continue;
      if (rule.action != RoutingAction.direct) continue;
      for (final d in rule.domains) {
        out.add(switch (rule.domainType) {
          RuleDomainMatchType.suffix => 'domain:$d',
          RuleDomainMatchType.exact => 'full:$d',
          RuleDomainMatchType.keyword => 'keyword:$d',
          RuleDomainMatchType.regex => 'regexp:$d',
        });
      }
    }
    return out;
  }
  // ---------------- outbounds ----------------

  List<Map<String, dynamic>> _buildOutbounds(List<VpnNodeData> nodes) {
    final List<Map<String, dynamic>> outbounds = [];

    // Proxy outbounds stay FIRST: Xray has no routing.final, so an
    // unmatched connection falls through to outbounds[0].
    for (final node in nodes) {
      outbounds.add(_buildSingleNodeOutbound(node));
    }

    outbounds.addAll([
      {
        "tag": "direct",
        "protocol": "freedom",
        // UseIPv4: the physical interface usually has no working IPv6
        // route, and AsIs would happily pick an AAAA record.
        "settings": {"domainStrategy": "UseIPv4"},
      },
      {
        "tag": "block",
        "protocol": "blackhole",
        "settings": {
          "response": {"type": "none"},
        },
      },
      {"tag": "dns-out", "protocol": "dns"},
    ]);

    return outbounds;
  }

  Map<String, dynamic> _buildSingleNodeOutbound(VpnNodeData node) {
    final proto = node.protocol;
    final p = node.params;
    final isTls = p['security'] == 'tls' || p['security'] == 'reality';
    final isReality = p['security'] == 'reality';
    final netType = p['type'] ?? p['net'] ?? 'tcp';

    // StreamSettings (Транспорт + TLS)
    final Map<String, dynamic> streamSettings = {
      "network": netType,
      "security": isReality
          ? "reality"
          : isTls
          ? "tls"
          : "none",
    };

    if (isTls && !isReality) {
      streamSettings["tlsSettings"] = {
        "serverName": p['sni'] ?? node.address,
        "allowInsecure": p['allowInsecure'] == '1' || p['insecure'] == 'true',
        if (p['alpn'] != null) "alpn": p['alpn']!.split(','),
        if (p['fp'] != null) "fingerprint": p['fp']!,
      };
    }

    if (isReality) {
      streamSettings["realitySettings"] = {
        "serverName": p['sni'] ?? node.address,
        "publicKey": p['pbk'] ?? "",
        "shortId": p['sid'] ?? "",
        if (p['fp'] != null) "fingerprint": p['fp']!,
        if (p['spx'] != null) "spiderX": p['spx']!,
      };
    }

    if (netType == 'ws') {
      streamSettings["wsSettings"] = {
        "path": p['path'] ?? "/",
        "headers": {if (p['host'] != null) "Host": p['host']!},
      };
    } else if (netType == 'grpc') {
      streamSettings["grpcSettings"] = {
        "serviceName": p['serviceName'] ?? p['path'] ?? "",
        "multiMode": p['mode'] == 'multi',
      };
    } else if (netType == 'h2' || netType == 'http') {
      streamSettings["httpSettings"] = {
        "path": p['path'] ?? "/",
        "host": p['host'] != null ? [p['host']!] : [node.address],
      };
    } else if (netType == 'httpupgrade') {
      streamSettings["httpupgradeSettings"] = {
        "path": p['path'] ?? "/",
        "host": p['host'] ?? node.address,
      };
    }

    final Map<String, dynamic> outbound = {
      "tag": node.name,
      "protocol": proto.name,
    };

    switch (proto) {
      case ProtocolTypes.vless:
        outbound["streamSettings"] = streamSettings;
        outbound["settings"] = {
          "vnext": [
            {
              "address": node.address,
              "port": node.port,
              "users": [
                {
                  "id": node.credential,
                  "encryption": p['encryption'] ?? "none",
                  "flow": p['flow'] ?? "",
                },
              ],
            },
          ],
        };

      case ProtocolTypes.vmess:
        outbound["streamSettings"] = streamSettings;
        outbound["settings"] = {
          "vnext": [
            {
              "address": node.address,
              "port": node.port,
              "users": [
                {
                  "id": node.credential,
                  "alterId": int.tryParse(p['aid'] ?? '0') ?? 0,
                  "security": p['scy'] ?? "auto",
                },
              ],
            },
          ],
        };

      case ProtocolTypes.trojan:
        outbound["streamSettings"] = streamSettings;
        outbound["settings"] = {
          "servers": [
            {
              "address": node.address,
              "port": node.port,
              "password": node.credential,
            },
          ],
        };

      case ProtocolTypes.shadowsocks:
        outbound["streamSettings"] = streamSettings;
        outbound["settings"] = {
          "servers": [
            {
              "address": node.address,
              "port": node.port,
              "method": p['method'] ?? 'chacha20-ietf-poly1305',
              "password": node.credential,
              "ota": false,
            },
          ],
        };

      case ProtocolTypes.wireguard:
        outbound["protocol"] = "wireguard";
        outbound["settings"] = {
          "secretKey": node.credential,
          "address": (p['local_address'] ?? '10.0.0.2/32').split(','),
          "peers": [
            {
              "publicKey": p['peer_public_key'] ?? p['public_key'] ?? '',
              "endpoint": "${node.address}:${node.port}",
              if (p['preshared_key'] != null)
                "preSharedKey": p['preshared_key'],
            },
          ],
          if (p['mtu'] != null) "mtu": int.tryParse(p['mtu']!),
          if (p['reserved'] != null)
            "reserved": p['reserved']!.split(',').map(int.parse).toList(),
        };

      case ProtocolTypes.hysteria2:
      case ProtocolTypes.tuic:
      case ProtocolTypes.ssh:
      default:
        throw UnsupportedProtocolException(
          providedProtocolType: proto,
          sellectedVpnCore: core,
          supportStatus: ProtocolSupportStatus.unsupported,
        );
    }

    return outbound;
  }

  // ---------------- routing ----------------

  Map<String, dynamic> _buildRouting(
    TunConfig tun,
    List<RoutingRule> customRules,
    OutboundGroup? activeGroup,
    List<VpnNodeData> nodes,
  ) {
    final hasBalancer = _usesBalancer(activeGroup, nodes);
    final balancerTag = _balancerTag(activeGroup);
    final defaultProxyTarget = nodes.isNotEmpty ? nodes.first.name : 'direct';

    /// Single funnel for "send this through the tunnel", so balancer and
    /// plain-outbound semantics stay identical in every rule.
    Map<String, dynamic> proxyTarget() => {
      if (hasBalancer)
        "balancerTag": balancerTag
      else
        "outboundTag": defaultProxyTarget,
    };

    // RULE ORDER IS SEMANTIC. Do not reorder without re-reading the notes.
    final List<Map<String, dynamic>> rules = [];

    // (1) QUIC kill-switch. FIRST, before anything else can claim UDP/443.
    //     Provider parity: "[socks -> block]" in the access log.
    //     Lives in the builder, not in a preset: a preset cannot guarantee it
    //     runs before the LAN and DNS rules.
    if (blockQuic) {
      rules.add({
        "type": "field",
        "network": "udp",
        "port": "443",
        "outboundTag": "block",
      });
    }

    // (2) LAN / loopback / CGNAT bypass. MUST precede the port-53 rule,
    //     otherwise a DNS query to the home router (192.168.1.1:53) is
    //     swallowed by dns-out instead of reaching the router.
    if (tun.bypassLan) {
      rules.add({
        "type": "field",
        "ip": kXrayPrivateCidrs,
        "outboundTag": "direct",
      });
    }

    // (3) Everything else on port 53 is answered INSIDE Xray (DoH), so the
    //     ISP never observes a cleartext query.
    rules.add({
      "type": "field",
      "network": "tcp,udp",
      "port": "53",
      "outboundTag": "dns-out",
    });

    // (4) Bootstrap: the DoH endpoints must themselves go through the tunnel,
    //     otherwise the resolver leaks and UDP/TCP 443 to 1.1.1.1 from a RU
    //     ISP is unreliable.
    if (tunnelDns) {
      final domains = <String>[];
      final ips = <String>[];
      for (final resolver in _kDefaultDohResolvers) {
        domains.addAll(resolver.domainRules);
        ips.addAll(resolver.ips);
      }
      rules.add({...proxyTarget(), "type": "field", "domain": domains});
      rules.add({...proxyTarget(), "type": "field", "ip": ips});
    }

    // (4b) The DIRECT DoH resolver must itself bypass the tunnel, otherwise
    //      the split is meaningless (it would resolve from the exit anyway).
    if (tunnelDns && directDnsServer != null) {
      final host = Uri.parse(directDnsServer!).host;
      if (host.isNotEmpty) {
        rules.add({
          "type": "field",
          "domain": ["domain:$host"],
          "outboundTag": "direct",
        });
      }
    }

    // (5) User/built-in presets. Projection is shared with sing-box
    //     (routing_rules.dart) so both cores stay in lock-step on what is
    //     expressible.
    final projection = projectXrayRules(
      customRules,
      proxyTarget: proxyTarget,
      nodes: nodes,
    );
    _lastProjection = projection;
    rules.addAll(projection.rules);

    // (6) Explicit catch-all. Xray has no routing.final: without this rule the
    //     default is silently "outbounds[0]", which breaks the moment someone
    //     reorders the outbound list.
    rules.add({...proxyTarget(), "type": "field", "network": "tcp,udp"});

    return {
      // IPIfNonMatch: the IP-based rules above (private ranges, pinned DoH
      // IPs) must also match domain destinations. AsIs silently disables
      // them, which is how LAN traffic used to leak into the tunnel.
      //
      // EXCEPTION: Xray per-app routing (rule "process", PR #5915) requires
      // AsIs - with IPIfNonMatch TCP connections randomly get UID -1
      // (issue #5980). If per-app rules are ever enabled, flip this to AsIs
      // AND set sniffing.routeOnly = true in the same change.
      "domainStrategy": routingDomainStrategy,
      if (hasBalancer)
        "balancers": [
          {
            "tag": balancerTag,
            "selector": _selector(activeGroup, nodes),
            if (balancerFallbackTag != null) "fallbackTag": balancerFallbackTag,
            "strategy": {
              // Xray only accepts: random | roundRobin | leastPing | leastLoad.
              "type": switch (activeGroup?.type) {
                OutboundGroupType.urlTest => "leastPing",
                OutboundGroupType.roundRobin => "roundRobin",
                OutboundGroupType.random => "random",
                _ => "leastPing",
              },
            },
          },
        ],
      "rules": rules,
    };
  }
}
