import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/exceptions/vpn_service_exception.dart';
import 'package:any_core_vpn/vpn_service/link_parsers/link_parser.dart';
import 'package:any_core_vpn/vpn_service/vpn_node_data.dart';

part 'singbox_config_builder.dart';
part 'xray_config_builder.dart';
part 'feature_models/switching.dart';
part 'feature_models/routing_rules.dart';
part 'feature_models/protocol_supported.dart';

enum TunStack {
  /// Recomended
  mixed,   
  /// Prefered for UDP
  gvisor,  
  /// Base tcp etc (for enhanced speed)
  system,  
}

class TunConfig {
  /// Use 1400 by default (not more 1500 in commone), in some gvisor cases can be increased to 1500
  final int mtu;

  final TunStack stack;

  final bool bypassLan;

  /// Supported only by Android; (for iOs we can use alternative only in case of enterprise apps, so it's not supported by this plugin)
  final List<String> includedApps;

  /// Supported only by Android; (for iOs we can use alternative only in case of enterprise apps, so it's not supported by this plugin)
  final List<String> excludedApps;

  final List<String>? customDnsServers;

  final bool enableDnsHijacking;

  final bool strictRoute;

  final bool enableSniffing;

  final String inet4Address;
  final String inet4RouteAddress;

  final String inet6Address;

  const TunConfig({
    this.mtu = 1500,
    this.stack = TunStack.mixed,
    this.bypassLan = true,
    this.includedApps = const [],
    this.excludedApps = const [],
    this.customDnsServers = const ['1.1.1.1', '8.8.8.8'],
    this.enableDnsHijacking = true,
    this.strictRoute = true,
    this.enableSniffing = true,
    this.inet4Address = '172.19.0.1/30',
    this.inet4RouteAddress = '0.0.0.0/0',
    this.inet6Address = 'fdfe:dcba:9876::1/126',
  });

  Map<String, dynamic> toAndroidOsParams() {
    final ipParts = inet4Address.split('/');
    final ip = ipParts[0];
    final prefix = int.tryParse(ipParts.length > 1 ? ipParts[1] : '30') ?? 30;

    return {
      'mtu': mtu,
      'address': ip,
      'prefix': prefix,
      'routes': [
        {'address': '0.0.0.0', 'prefix': 0},
        if (inet6Address.isNotEmpty) {'address': '::', 'prefix': 0},
      ],
      'dnsServers': customDnsServers,
      'includedApps': includedApps,
      'excludedApps': excludedApps,
      'bypassLan': bypassLan,
      'strictRoute': strictRoute,
    };
  }

  Map<String, dynamic> toIosOsParams() {
  final ipParts = inet4Address.split('/');
  final ip = ipParts[0];
  final prefix = int.tryParse(ipParts.length > 1 ? ipParts[1] : '30') ?? 30;
  final subnetMask = _prefixToSubnetMask(prefix);

  return {
    'mtu': mtu,
    'tunnelRemoteAddress': '172.19.0.2',
    'ipv4Settings': {
      'addresses': [ip],
      'subnetMasks': [subnetMask], // Динамическая маска на основе prefix
      'includedRoutes': [{'address': '0.0.0.0', 'subnetMask': '0.0.0.0'}],
      'excludedRoutes': bypassLan
          ? [
              {'address': '192.168.0.0', 'subnetMask': '255.255.0.0'},
              {'address': '10.0.0.0', 'subnetMask': '255.0.0.0'},
              {'address': '172.16.0.0', 'subnetMask': '255.240.0.0'},
            ]
          : [],
    },
    'dnsSettings': {
      'servers': customDnsServers,
      'matchDomains': [''],
    },
  };
  }

  Map<String, dynamic> toDesktopOsParams() {
    return {
      'mtu': mtu,
      'dnsServers': customDnsServers,
      'bypassLan': bypassLan,
      'strictRoute': strictRoute,
    };
  }

  String _prefixToSubnetMask(int prefix) {
    if (prefix <= 0) return '0.0.0.0';
    if (prefix >= 32) return '255.255.255.255';
    
    final mask = (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF;
    return '${(mask >> 24) & 0xFF}.${(mask >> 16) & 0xFF}.${(mask >> 8) & 0xFF}.${mask & 0xFF}';
  }
}


sealed class VpnCoreConfigBuilder {
  VpnCore get core;

  RoutingProjection? get lastProjection => _lastProjection;

  RoutingProjection? _lastProjection;

  Map<String, dynamic> buildConfig({
    required List<VpnNodeData> nodes,
    required OutboundGroup? activeGroup,
    required List<RoutingRule> customRules,
    required TunConfig tunConfig,
  });

  void validateProtocolSupported(VpnNodeData node, SupportedPlatforms platform) {
    final status = ProtocolSupportedChecker.isProtocolSupported(
        node.protocol, platform, core);

    if (status == ProtocolSupportStatus.supported) return;

    throw UnsupportedProtocolException(
      providedProtocolType: node.protocol,
      supportStatus: status,
      sellectedVpnCore: core,
    );
  }
}