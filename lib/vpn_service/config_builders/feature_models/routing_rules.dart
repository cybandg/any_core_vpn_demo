part of '../core_config_builder.dart';

enum RoutingAction {
  proxy,
  direct,
  block,
}

enum RuleDomainMatchType {
  keyword,
  suffix,
  exact,
  regex,
}

/// Transport a rule applies to. [RoutingNetwork.both] omits the field.
enum RoutingNetwork {
  tcp,
  udp,
  both;

  /// Xray accepts a comma-separated string; sing-box accepts "tcp"/"udp".
  String get xrayValue => switch (this) {
        RoutingNetwork.tcp => 'tcp',
        RoutingNetwork.udp => 'udp',
        RoutingNetwork.both => 'tcp,udp',
      };

  String get singboxValue => switch (this) {
        RoutingNetwork.tcp => 'tcp',
        RoutingNetwork.udp => 'udp',
        // Unreachable: `both` omits the field instead of emitting it.
        RoutingNetwork.both => 'tcp',
      };
}

// ===========================================================================
// Core capability declarations
// ===========================================================================

/// Route-rule keys sing-box (libbox 1.14.x) accepts.
///
/// sing-box decodes configs STRICTLY: one unknown key aborts the WHOLE config
/// with `json: unknown field "..."`, which surfaces to the user as "never
/// reaches connected" with no visible error. This allow-list turns that into a
/// readable Dart error at config-build time. Verify against option/rule.go
/// when libbox is upgraded.
const Set<String> kSingboxRouteRuleKeys = <String>{
  'type',
  'inbound',
  'network',
  'protocol',
  'domain',
  'domain_suffix',
  'domain_keyword',
  'domain_regex',
  'source_ip_cidr',
  'source_ip_is_private',
  'ip_cidr',
  'ip_is_private',
  'ip_accept_any',
  'rule_set',
  'rule_set_ip_cidr_match_source',
  'rule_set_ip_is_private',
  'rule_set_ip_accept_any',
  'source_port',
  'source_port_range',
  'port',
  'port_range',
  'process_name',
  'process_path',
  'process_path_regex',
  'package_name',
  'user',
  'user_id',
  'clash_mode',
  'invert',
  'action',
  'outbound',
  // sniff action options
  'timeout',
  'sniff_timeout',
};

/// Routing-rule keys Xray accepts. Xray IGNORES unknown fields, so this list
/// is a lint (logged), not a hard failure.
/// `process` = UID-based Android routing (Xray-core PR #5915, needs
/// LibXray.registerProcessFinder + sniffing.routeOnly + domainStrategy AsIs).
const Set<String> kXrayRoutingRuleKeys = <String>{
  'type',
  'domain',
  'ip',
  'port',
  'portRange',
  'network',
  'source',
  'sourcePort',
  'sourcePortRange',
  'protocol',
  'attrs',
  'inboundTag',
  'outboundTag',
  'balancerTag',
  'user',
  'process',
};

/// Throws when a sing-box rule carries a key the core would reject.
///
/// [origin] names the producer (builder section or preset/rule id) because
/// "which rule killed the config" is otherwise unknowable.
void validateSingboxRouteRule(
  Map<String, dynamic> rule, {
  required String origin,
}) {
  final unknown =
      rule.keys.where((k) => !kSingboxRouteRuleKeys.contains(k)).toList();
  if (unknown.isEmpty) return;

  throw StateError(
    'sing-box route rule rejected before send (origin: $origin): '
    'unsupported key(s) $unknown.\n'
    'sing-box decodes strictly - one unknown field aborts the whole config '
    'and the core never reaches "connected".\n'
    'Rule: $rule',
  );
}

/// Xray-unknown keys of a routing rule (lint only - Xray ignores them).
List<String> xrayRoutingRuleLint(Map<String, dynamic> rule) =>
    rule.keys.where((k) => !kXrayRoutingRuleKeys.contains(k)).toList();

// ===========================================================================
// IPv4 helpers
// ===========================================================================

/// True when [ip] falls inside [cidr]. IPv4 only, deliberately.
bool ipv4CidrContains(String cidr, String ip) {
  final parts = cidr.split('/');
  if (parts.length != 2) return false;

  final network = _ipv4ToInt(parts[0]);
  final target = _ipv4ToInt(ip);
  final prefix = int.tryParse(parts[1]);

  if (network == null || target == null || prefix == null) return false;
  if (prefix < 0 || prefix > 32) return false;

  final mask = prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
  return (network & mask) == (target & mask);
}

int? _ipv4ToInt(String value) {
  final octets = value.trim().split('.');
  if (octets.length != 4) return null;
  var result = 0;
  for (final octet in octets) {
    final parsed = int.tryParse(octet);
    if (parsed == null || parsed < 0 || parsed > 255) return null;
    result = (result << 8) | parsed;
  }
  return result;
}

/// [cidrs] minus every range containing one of [protectedIps].
///
/// A `direct` rule covering the VPN server's own address would push the
/// tunnel's traffic out directly and silently kill the connection.
List<String> ipCidrsExcludingNodes(
    List<String> cidrs, List<String> protectedIps) {
  if (protectedIps.isEmpty || cidrs.isEmpty) return cidrs;
  return cidrs
      .where((cidr) => !protectedIps.any((ip) => ipv4CidrContains(cidr, ip)))
      .toList(growable: false);
}

// ===========================================================================
// Rule
// ===========================================================================

class RoutingRule {
  final String? id;

  final RoutingAction action;

  final List<String> domains;
  final RuleDomainMatchType domainType;
  final List<String> domainSets;

  final List<String> ipCidrs;
  final List<String> ipSets;

  final List<int> ports;
  final List<String> protocols;
  final List<String> sourceApps;

  /// Restrict the rule to one transport. [RoutingNetwork.both] omits the field.
  final RoutingNetwork network;

  /// Disabled rules are skipped by both projections, so a preset can carry
  /// rules the user toggles without deleting them.
  final bool enabled;

  /// Free-form note for the editor. Never reaches the core config.
  final String? comment;

  const RoutingRule({
    this.id,
    required this.action,
    this.domains = const [],
    this.domainType = RuleDomainMatchType.suffix,
    this.domainSets = const [],
    this.ipCidrs = const [],
    this.ipSets = const [],
    this.ports = const [],
    this.protocols = const [],
    this.sourceApps = const [],
    this.network = RoutingNetwork.both,
    this.enabled = true,
    this.comment,
  });

  bool get hasCriteria =>
      domains.isNotEmpty ||
      domainSets.isNotEmpty ||
      ipCidrs.isNotEmpty ||
      ipSets.isNotEmpty ||
      ports.isNotEmpty ||
      protocols.isNotEmpty ||
      sourceApps.isNotEmpty ||
      network != RoutingNetwork.both;

  /// Criteria this core cannot express. Surfaced in the UI so "my rule does
  /// nothing on Xray" is never a mystery.
  ///
  /// Xray has no source-app visibility in its SOCKS/TUN path unless a process
  /// finder is registered (LibXray.registerProcessFinder). Neither core can
  /// use geosite/geoip here: Xray needs the .dat assets shipped (we do not
  /// ship them), sing-box removed them in 1.11+ in favour of rule_set.
  List<String> unsupportedCriteria(VpnCore core) {
    final unsupported = <String>[];
    switch (core) {
      case VpnCore.xray:
        if (sourceApps.isNotEmpty) unsupported.add('apps');
        if (domainSets.isNotEmpty) unsupported.add('geosite sets');
        if (ipSets.isNotEmpty) unsupported.add('geoip sets');
      case VpnCore.singbox:
        if (domainSets.isNotEmpty) unsupported.add('geosite sets');
        if (ipSets.isNotEmpty) unsupported.add('geoip sets');
    }
    return unsupported;
  }

  /// False => the projection MUST drop this rule entirely.
  ///
  /// Dropping matters: a rule that loses every criterion would become an empty
  /// field-rule, which matches EVERY connection and would silently send the
  /// whole device direct (or to block).
  bool isUsableBy(VpnCore core) {
    if (!enabled) return false;

    final usable = switch (core) {
      VpnCore.xray =>
        domains.isNotEmpty ||
            ipCidrs.isNotEmpty ||
            ports.isNotEmpty ||
            protocols.isNotEmpty ||
            network != RoutingNetwork.both,
      VpnCore.singbox =>
        domains.isNotEmpty ||
            ipCidrs.isNotEmpty ||
            ports.isNotEmpty ||
            protocols.isNotEmpty ||
            sourceApps.isNotEmpty ||
            network != RoutingNetwork.both,
    };

    return usable;
  }

  String describe({int maxItems = 3}) {
    final items = <String>[
      ...domains,
      ...domainSets.map((s) => 'geosite:$s'),
      ...ipCidrs,
      ...ipSets.map((s) => 'geoip:$s'),
      if (ports.isNotEmpty) 'ports: ${ports.join(',')}',
      ...protocols.map((p) => 'proto:$p'),
      ...sourceApps,
      if (network != RoutingNetwork.both) 'net:${network.name}',
    ];
    if (items.isEmpty) return '(no criteria)';
    if (items.length <= maxItems) return items.join(', ');
    return '${items.take(maxItems).join(', ')} …+${items.length - maxItems}';
  }

  RoutingRule copyWith({
    String? id,
    RoutingAction? action,
    List<String>? domains,
    RuleDomainMatchType? domainType,
    List<String>? domainSets,
    List<String>? ipCidrs,
    List<String>? ipSets,
    List<int>? ports,
    List<String>? protocols,
    List<String>? sourceApps,
    RoutingNetwork? network,
    bool? enabled,
    String? comment,
  }) {
    return RoutingRule(
      id: id ?? this.id,
      action: action ?? this.action,
      domains: domains ?? this.domains,
      domainType: domainType ?? this.domainType,
      domainSets: domainSets ?? this.domainSets,
      ipCidrs: ipCidrs ?? this.ipCidrs,
      ipSets: ipSets ?? this.ipSets,
      ports: ports ?? this.ports,
      protocols: protocols ?? this.protocols,
      sourceApps: sourceApps ?? this.sourceApps,
      network: network ?? this.network,
      enabled: enabled ?? this.enabled,
      comment: comment ?? this.comment,
    );
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'action': action.name,
        'domainType': domainType.name,
        'domains': domains,
        'domainSets': domainSets,
        'ipCidrs': ipCidrs,
        'ipSets': ipSets,
        'ports': ports,
        'protocols': protocols,
        'sourceApps': sourceApps,
        'network': network.name,
        'enabled': enabled,
        if (comment != null) 'comment': comment,
      };

  factory RoutingRule.fromJson(Map<String, dynamic> json) {
    T enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    List<String> strings(Object? raw) => raw is List
        ? [for (final e in raw) if (e != null) e.toString()]
        : const [];

    List<int> ints(Object? raw) => raw is List
        ? [
            for (final e in raw)
              if (e is int) e else if (e is String) int.tryParse(e) ?? -1,
          ].where((p) => p > 0).toList()
        : const [];

    return RoutingRule(
      id: json['id'] as String?,
      action: enumByName(
          RoutingAction.values, json['action'] as String?, RoutingAction.proxy),
      domainType: enumByName(RuleDomainMatchType.values,
          json['domainType'] as String?, RuleDomainMatchType.suffix),
      domains: strings(json['domains']),
      domainSets: strings(json['domainSets']),
      ipCidrs: strings(json['ipCidrs']),
      ipSets: strings(json['ipSets']),
      ports: ints(json['ports']),
      protocols: strings(json['protocols']),
      sourceApps: strings(json['sourceApps']),
      // Absent in older snapshots -> both, i.e. pre-existing behaviour.
      network: enumByName(RoutingNetwork.values, json['network'] as String?,
          RoutingNetwork.both),
      enabled: json['enabled'] != false,
      comment: json['comment'] as String?,
    );
  }
}

// ===========================================================================
// Projection: rule -> core syntax (single source of truth for both builders)
// ===========================================================================

/// Result of projecting rules onto one core.
class RoutingProjection {
  const RoutingProjection({
    required this.rules,
    this.dropped = const [],
    this.lint = const [],
  });

  final List<Map<String, dynamic>> rules;

  /// Human-readable reasons a rule produced nothing (surface in UI/logs).
  final List<String> dropped;

  /// Non-fatal notes (CIDR removed because it covered the VPN node, unknown
  /// Xray keys).
  final List<String> lint;

  bool get hasNotes => dropped.isNotEmpty || lint.isNotEmpty;

  @override
  String toString() =>
      'rules=${rules.length} dropped=$dropped lint=$lint';
}

/// Projects [rules] onto Xray `routing.rules[]`.
///
/// [proxyTarget] returns the "send through the tunnel" fields for the current
/// config (`outboundTag` or `balancerTag`), so balancer and single-node
/// semantics stay identical.
RoutingProjection projectXrayRules(
  List<RoutingRule> rules, {
  required Map<String, dynamic> Function() proxyTarget,
  required List<VpnNodeData> nodes,
}) {
  final out = <Map<String, dynamic>>[];
  final dropped = <String>[];
  final lint = <String>[];

  final protectedIps = <String>[
    for (final node in nodes)
      if (node.address.contains('.')) node.address,
  ];

  for (final rule in rules) {
    final label = rule.comment ?? rule.id ?? rule.describe(maxItems: 1);

    if (!rule.enabled) continue;

    if (!rule.isUsableBy(VpnCore.xray)) {
      dropped.add('"$label": no criteria Xray can express '
          '(unsupported: ${rule.unsupportedCriteria(VpnCore.xray)})');
      continue;
    }

    final projected = <String, dynamic>{'type': 'field'};

    final domains = <String>[];
    for (final d in rule.domains) {
      switch (rule.domainType) {
        case RuleDomainMatchType.suffix:
          domains.add('domain:$d');
        case RuleDomainMatchType.keyword:
          domains.add('keyword:$d');
        case RuleDomainMatchType.exact:
          domains.add('full:$d');
        case RuleDomainMatchType.regex:
          domains.add('regexp:$d');
      }
    }
    if (domains.isNotEmpty) projected['domain'] = domains;

    final cidrs = ipCidrsExcludingNodes(rule.ipCidrs, protectedIps);
    if (cidrs.length != rule.ipCidrs.length) {
      lint.add('"$label": dropped '
          '${rule.ipCidrs.length - cidrs.length} CIDR(s) covering the VPN '
          'server address');
    }
    if (cidrs.isNotEmpty) projected['ip'] = cidrs;

    if (rule.ports.isNotEmpty) projected['port'] = rule.ports.join(',');

    if (rule.protocols.isNotEmpty) projected['protocol'] = rule.protocols;

    if (rule.network != RoutingNetwork.both) {
      projected['network'] = rule.network.xrayValue;
    }

    // Guard against an all-criteria-lost rule matching everything.
    if (projected.length == 1) {
      dropped.add('"$label": became empty after projection');
      continue;
    }

    switch (rule.action) {
      case RoutingAction.proxy:
        projected.addAll(proxyTarget());
      case RoutingAction.direct:
        projected['outboundTag'] = 'direct';
      case RoutingAction.block:
        projected['outboundTag'] = 'block';
    }

    final unknown = xrayRoutingRuleLint(projected);
    if (unknown.isNotEmpty) {
      lint.add('"$label": unknown Xray keys $unknown (ignored by the core)');
    }

    out.add(projected);
  }

  return RoutingProjection(rules: out, dropped: dropped, lint: lint);
}

/// Projects [rules] onto sing-box `route.rules[]`.
///
/// Every emitted rule is validated against [kSingboxRouteRuleKeys] and throws
/// with the offending rule named - far better than the core's
/// `json: unknown field` after a 12 s silent hang.
RoutingProjection projectSingboxRules(
  List<RoutingRule> rules, {
  required String proxyTag,
  required List<VpnNodeData> nodes,
}) {
  final out = <Map<String, dynamic>>[];
  final dropped = <String>[];
  final lint = <String>[];

  final protectedIps = <String>[
    for (final node in nodes)
      if (node.address.contains('.')) node.address,
  ];

  for (final rule in rules) {
    final label = rule.comment ?? rule.id ?? rule.describe(maxItems: 1);

    if (!rule.enabled) continue;

    if (!rule.isUsableBy(VpnCore.singbox)) {
      dropped.add('"$label": no criteria sing-box can express '
          '(unsupported: ${rule.unsupportedCriteria(VpnCore.singbox)})');
      continue;
    }

    final projected = <String, dynamic>{};

    if (rule.domains.isNotEmpty) {
      switch (rule.domainType) {
        case RuleDomainMatchType.suffix:
          projected['domain_suffix'] = rule.domains;
        case RuleDomainMatchType.keyword:
          projected['domain_keyword'] = rule.domains;
        case RuleDomainMatchType.exact:
          projected['domain'] = rule.domains;
        case RuleDomainMatchType.regex:
          projected['domain_regex'] = rule.domains;
      }
    }

    final cidrs = ipCidrsExcludingNodes(rule.ipCidrs, protectedIps);
    if (cidrs.length != rule.ipCidrs.length) {
      lint.add('"$label": dropped '
          '${rule.ipCidrs.length - cidrs.length} CIDR(s) covering the VPN '
          'server address');
    }
    if (cidrs.isNotEmpty) projected['ip_cidr'] = cidrs;

    if (rule.ports.isNotEmpty) projected['port'] = rule.ports;

    if (rule.protocols.isNotEmpty) projected['protocol'] = rule.protocols;

    if (rule.sourceApps.isNotEmpty) projected['package_name'] = rule.sourceApps;

    if (rule.network != RoutingNetwork.both) {
      projected['network'] = rule.network.singboxValue;
    }

    if (projected.isEmpty) {
      dropped.add('"$label": became empty after projection');
      continue;
    }

    switch (rule.action) {
      case RoutingAction.proxy:
        projected['outbound'] = proxyTag;
      case RoutingAction.direct:
        projected['outbound'] = 'direct';
      case RoutingAction.block:
        // The "block" outbound was removed in sing-box 1.11+; reject replaced
        // it as an ACTION.
        projected['action'] = 'reject';
    }

    validateSingboxRouteRule(projected, origin: 'preset rule "$label"');

    out.add(projected);
  }

  return RoutingProjection(rules: out, dropped: dropped, lint: lint);
}

// ===========================================================================
// Geo data (consumed by BuiltInRoutingPresets)
// ===========================================================================

/// Curated RU-resident services. Suffix match. Data, not logic - edit freely.
const List<String> kRuResidentDomains = <String>[
  // Yandex
  'yandex.ru', 'yandex.net', 'yandex.com', 'ya.ru', 'yastatic.net',
  'yandexcloud.net', 'kinopoisk.ru', 'auto.ru', 'beru.ru', 'edadeal.ru',
  // VK / Mail.ru
  'vk.com', 'vk.ru', 'vk.me', 'vkontakte.ru', 'vkuseraudio.com', 'vkvideo.ru',
  'mail.ru', 'list.ru', 'inbox.ru', 'bk.ru', 'internet.ru',
  'ok.ru', 'mytarget.ru', 'dmp.wi-fi.ru', 'delivery-club.ru',
  // Gov / taxes
  'gosuslugi.ru', 'nalog.ru', 'nalog.gov.ru', 'mos.ru', 'cbr.ru', 'mir.ru',
  'nspk.ru', 'zakupki.gov.ru', 'sudact.ru', 'arbitr.ru',
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
  'rzd.ru', 'tutu.ru', 'poezdrf.ru', 'gosuslugi.com',
];

/// RU IP space for clients that dial hard-coded IPs (VK / Telegram / banking),
/// where sniffing yields no domain and a domain rule can never match.
///
/// STARTER SET derived from addresses observed in real access logs.
/// VERIFY before shipping (RIPE stat / whois): a wrong range silently sends
/// foreign traffic direct. The builders additionally strip any CIDR covering
/// the VPN server address, so a mistake there cannot kill the tunnel.
const List<String> kRuResidentCidrs = <String>[
  // Yandex
  '5.45.192.0/18',
  '5.255.192.0/18',
  '37.9.64.0/18',
  '37.140.128.0/18',
  '77.88.0.0/16',
  '84.201.128.0/18',
  '87.250.224.0/19',
  '93.158.128.0/18',
  '95.108.128.0/17',
  '141.8.128.0/18',
  '178.154.128.0/18',
  '213.180.192.0/19',
  '51.250.0.0/16', // Yandex Cloud

  // VK
  '79.133.168.0/21',
  '87.240.128.0/18',
  '95.213.0.0/17',
  '193.238.132.0/22',
  '217.69.128.0/19',

  // Mail.ru / VK group
  '94.100.176.0/20',
  '95.163.32.0/19',
  '217.20.144.0/20',
  '87.242.64.0/18',

  // Rambler / Sber / Tinkoff / Ozon / Avito (observed ranges)
  '81.19.64.0/19',
  '185.12.152.0/22',
  '95.163.224.0/20',
];

/// Curated TR-resident services. ccTLD regex alone is NOT enough: many
/// national services live on .com (trendyol.com, mynet.com).
const List<String> kTrResidentDomains = <String>[
  // Gov
  'turkiye.gov.tr', 'gib.gov.tr', 'sgk.gov.tr', 'nvi.gov.tr', 'meb.gov.tr',
  'yok.gov.tr', 'osym.gov.tr', 'dhmi.gov.tr', 'icisleri.gov.tr',
  'saglik.gov.tr', 'adalet.gov.tr', 'hmb.gov.tr',
  // Banking
  'isbank.com.tr', 'garanti.com.tr', 'akbank.com', 'yapikredi.com.tr',
  'ziraatbank.com.tr', 'vakifbank.com.tr', 'halkbank.com.tr',
  'qnbfinansbank.com', 'enpara.com', 'denizbank.com', 'teb.com.tr',
  'kuveytturk.com.tr', 'albaraka.com.tr', 'papara.com', 'ininal.com',
  // Telecom
  'turktelekom.com.tr', 'ttnet.com.tr', 'turkcell.com.tr', 'vodafone.com.tr',
  'turksat.com.tr',
  // E-commerce / services
  'trendyol.com', 'hepsiburada.com', 'n11.com', 'sahibinden.com',
  'ciceksepeti.com', 'vatanbilgisayar.com.tr', 'mediamarkt.com.tr',
  'teknosa.com', 'migros.com.tr', 'a101.com.tr', 'bim.com.tr',
  'sokmarket.com.tr', 'yemeksepeti.com', 'getir.com', 'banabi.com.tr',
  'armut.com', 'modanisa.com',
  // Travel
  'turkishairlines.com', 'anadolujet.com', 'pegasusairlines.com',
  'sunexpress.com', 'obilet.com', 'biletix.com', 'passo.com.tr', 'enuygun.com',
  // Media
  'trthaber.com', 'trt.net.tr', 'hurriyet.com.tr', 'milliyet.com.tr',
  'sozcu.com.tr', 'sabah.com.tr', 'ntv.com.tr', 'haberturk.com',
  'cnnturk.com', 'posta.com.tr', 'takvim.com.tr', 'yenisafak.com',
  'eksisozluk.com', 'mynet.com', 'onedio.com', 'haberler.com',
  'mackolik.com', 'sporx.com', 'fanatik.com.tr', 'beinsports.com.tr',
  // Utilities / post
  'epttavm.com', 'ptt.gov.tr', 'edas.com.tr', 'igdas.com.tr', 'aski.gov.tr',
];

/// Curated GB-resident services. Global marketplaces are intentionally absent:
/// sending amazon.co.uk direct would break geo-restricted access when a UK
/// exit is used from abroad.
const List<String> kGbResidentDomains = <String>[
  // Gov / public
  'gov.uk', 'nhs.uk', 'royalmail.com', 'tfl.gov.uk', 'nationalrail.co.uk',
  'dvla.gov.uk', 'metoffice.gov.uk', 'ordnancesurvey.co.uk',
  // Banking
  'lloydsbank.com', 'bankofscotland.co.uk', 'halifax.co.uk', 'barclays.co.uk',
  'hsbc.co.uk', 'natwest.com', 'rbs.co.uk', 'ulsterbank.co.uk',
  'santander.co.uk', 'nationwide.co.uk', 'monzo.com', 'starlingbank.com',
  'metrobankonline.co.uk', 'tsb.co.uk', 'yorkshirebank.co.uk',
  // Telecom / energy
  'bt.com', 'btbroadband.com', 'sky.com', 'virginmedia.com', 'talktalk.co.uk',
  'vodafone.co.uk', 'three.co.uk', 'ee.co.uk', 'o2.co.uk', 'giffgaff.com',
  'britishgas.co.uk', 'edfenergy.com', 'sse.com', 'octopus.energy',
  'npower.com', 'eonenergy.com', 'scottishpower.co.uk',
  // Retail
  'tesco.com', 'sainsburys.co.uk', 'asda.com', 'morrisons.com',
  'aldi.co.uk', 'lidl.co.uk', 'waitrose.com', 'ocado.com', 'iceland.co.uk',
  'argos.co.uk', 'currys.co.uk', 'johnlewis.com', 'next.co.uk',
  'marksandspencer.com', 'boots.com', 'superdrug.com',
  'screwfix.com', 'toolstation.com', 'diy.com', 'wickes.co.uk',
  'halfords.com', 'sportsdirect.com', 'very.co.uk',
  // Travel
  'thetrainline.com', 'easyjet.com', 'britishairways.com',
  'virginatlantic.com', 'jet2.com', 'stagecoachbus.com',
  // Media
  'bbc.co.uk', 'itv.com', 'channel4.com', 'channel5.com',
  'skynews.com', 'theguardian.com', 'telegraph.co.uk', 'dailymail.co.uk',
  'independent.co.uk', 'mirror.co.uk', 'thesun.co.uk', 'express.co.uk',
  'metro.co.uk',
  // Property / jobs / delivery
  'rightmove.co.uk', 'zoopla.co.uk', 'onthemarket.com', 'reed.co.uk',
  'totaljobs.com', 'cv-library.co.uk', 'gumtree.com',
  'evri.com', 'yodel.co.uk', 'dpd.co.uk', 'parcelforce.com',
];