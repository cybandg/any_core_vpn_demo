/// Shipped (immutable) routing presets: geo splits and the "no split" case.
///
/// They live in code, NOT in storage: every app launch refreshes them from
/// [all], so updating a curated domain list reaches every user without any
/// migration. Editing a built-in is done by copying it into a user preset.
library;

import 'package:any_core_vpn/vpn_service/config_builders/core_config_builder.dart';
import 'package:any_core_vpn/vpn_service/rules/vpn_rules_service.dart';

abstract final class BuiltInRoutingPresets {
  static const String geoRuDirectName = 'geo-ru-direct';
  static const String geoRuProxyName = 'geo-ru-proxy';
  static const String geoTrDirectName = 'geo-tr-direct';
  static const String geoGbDirectName = 'geo-gb-direct';

  static const String _directWarning =
      'WARNING: "direct" is intentional exposure, not a leak. Those '
      'destinations see your REAL IP, so leak-check and speedtest pages '
      '(speedtest.yandex.ru, 2ip.ru) will report your ISP address. Apps still '
      'detect an active VPN via ConnectivityManager unless they are excluded '
      'from the VPN at OS level.';

  /// Russia resident traffic DIRECT - for users physically in RU.
  /// Lower RTT for local sites and far less volume inside the tunnel.
  static VpnRulePreset get geoRuDirect => VpnRulePreset(
        name: geoRuDirectName,
        title: 'Russian traffic → direct',
        description: 'Assumes you are physically in RU. Russian services '
            'bypass the tunnel. $_directWarning',
        builtIn: true,
        rules: _ruRules(RoutingAction.direct),
      );

  /// Russia resident traffic THROUGH the tunnel - for users abroad who need
  /// geo-locked RU content.
  static VpnRulePreset get geoRuProxy => VpnRulePreset(
        name: geoRuProxyName,
        title: 'Russian traffic → tunnel',
        description: 'For users OUTSIDE RU: force Russian services through the '
            'tunnel so they see the exit IP and unlock geo-restricted content.',
        builtIn: true,
        rules: _ruRules(RoutingAction.proxy),
      );

  static VpnRulePreset get geoTrDirect => VpnRulePreset(
        name: geoTrDirectName,
        title: 'Turkish traffic → direct',
        description: 'Assumes you are physically in TR. Many national services '
            'live on .com (trendyol.com, mynet.com), so the curated list '
            'matters more than the .tr regex. $_directWarning',
        builtIn: true,
        rules: const [
          RoutingRule(
            id: 'geo-tr-tld',
            action: RoutingAction.direct,
            domainType: RuleDomainMatchType.regex,
            domains: [r'.*\.tr$', r'.*\.com\.tr$'],
            comment: 'Turkish ccTLDs',
          ),
          RoutingRule(
            id: 'geo-tr-domains',
            action: RoutingAction.direct,
            domainType: RuleDomainMatchType.suffix,
            domains: kTrResidentDomains,
            comment: 'Curated Turkish resident services',
          ),
        ],
      );

  static VpnRulePreset get geoGbDirect => VpnRulePreset(
        name: geoGbDirectName,
        title: 'British traffic → direct',
        description: 'Assumes you are physically in GB. Global marketplaces are '
            'deliberately excluded. $_directWarning',
        builtIn: true,
        rules: const [
          RoutingRule(
            id: 'geo-gb-tld',
            action: RoutingAction.direct,
            domainType: RuleDomainMatchType.regex,
            domains: [r'.*\.uk$'],
            comment: 'UK ccTLDs (.co.uk, .gov.uk, .nhs.uk, ...)',
          ),
          RoutingRule(
            id: 'geo-gb-domains',
            action: RoutingAction.direct,
            domainType: RuleDomainMatchType.suffix,
            domains: kGbResidentDomains,
            comment: 'Curated British resident services',
          ),
        ],
      );

  static List<VpnRulePreset> get all => <VpnRulePreset>[
        geoRuDirect,
        geoRuProxy,
        geoTrDirect,
        geoGbDirect,
      ];

  static bool isBuiltInName(String name) =>
      all.any((preset) => preset.name == name);

  /// Three rules on purpose - the IP one is the important part: VK / Telegram
  /// / banking apps dial hard-coded IPs, where sniffing yields no domain and a
  /// domain rule can never match.
  static List<RoutingRule> _ruRules(RoutingAction action) => [
        RoutingRule(
          id: 'geo-ru-tld',
          action: action,
          domainType: RuleDomainMatchType.regex,
          domains: const [r'.*\.ru$', r'.*\.xn--p1ai$', r'.*\.su$'],
          comment: 'Russian ccTLDs',
        ),
        RoutingRule(
          id: 'geo-ru-domains',
          action: action,
          domainType: RuleDomainMatchType.suffix,
          domains: kRuResidentDomains,
          comment: 'Curated Russian resident services',
        ),
        RoutingRule(
          id: 'geo-ru-ip',
          action: action,
          ipCidrs: kRuResidentCidrs,
          comment: 'Russian IP space (apps dialing hard-coded IPs)',
        ),
      ];
}