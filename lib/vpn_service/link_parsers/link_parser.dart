library vpn_link_parser_lib;

import 'dart:convert';

import 'package:any_core_vpn/vpn_service/exceptions/vpn_service_exception.dart';
import 'package:any_core_vpn/vpn_service/vpn_node_data.dart';

part 'ss_link_parser.dart';
part 'vless_link_parser.dart';
part 'hysteria2_link_parser.dart';
part 'tuic_link_parser.dart';

enum ProtocolTypes{
  notSupported(["not_supported"]), //if not supported
  vmess(["vmess://"]),
  vless(["vless://"]),
  shadowsocks(["ss://"]),
  trojan(["trojan://"]),
  wireguard(["wg://", "wireguard://"]),
  hysteria2(["hy2://", "hysteria2://"]),//singbox only
  tuic(["tuic://"]),//singbox only
  ssh(["ssh://"]);//singbox only


  final List<String> value;

  const ProtocolTypes(this.value);

  static ProtocolTypes getTypeFromLink(String link){
    for(var ptcl in ProtocolTypes.values){
      for(var prefix in ptcl.value){
      if(link.startsWith(prefix)){
          return ptcl;
        }
      }
    }
    return ProtocolTypes.notSupported;
  }
}

abstract class LinkParser {
    factory LinkParser.createParserForLink(String link){
      var linkType = ProtocolTypes.getTypeFromLink(link);

      switch(linkType){
        case ProtocolTypes.vless:
          return VlessLinkParser();
        case ProtocolTypes.shadowsocks:
          return ShadowsocksLinkParser();
        case ProtocolTypes.hysteria2:
          return Hysteria2LinkParser();
        case ProtocolTypes.tuic:
          return TuicLinkParser();
        case ProtocolTypes.notSupported:
          throw NotSupportedVpnLinkTypeException(link: link);
        default:
          throw UnsupportedInDemoVersionException( featureDescriprion: "$linkType protocol suppotion");
      }
    }

    VpnNodeData parseLink(String link);
}

abstract class LinkParserBase implements LinkParser {

  /// Strips a leading scheme (case‑insensitive) from the raw link.
  String stripScheme(String link, ProtocolTypes protocol) {
    final l = link.trim();
    String? scheme;
    for(var prefix in protocol.value){
      if (l.toLowerCase().startsWith(prefix)) {
        scheme = prefix;
        break;
      }
    }
    if(scheme == null){
      throw InvalidVpnLinkTypeException(link: link, reason: "Expected a '${protocol.name}' link");
    }

    return l.substring(scheme.length);
  }

  /// Percent‑decode that never throws on malformed `%xx` (keeps a stray `+` as `+`).
  String safeDecode(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  String decodeFragment(String f) => f.isEmpty ? '' : safeDecode(f);

  /// Parse a raw query string. Decodes with `decodeComponent` (NOT query‑component),
  /// so a literal `+` in a value is preserved — important for `path`/`pbk`/`spx`.
  Map<String, String> parseQuery(String query) {
    final out = <String, String>{};
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq < 0) {
        out[safeDecode(pair).toLowerCase()] = '';
      } else {
        out[safeDecode(pair.substring(0, eq)).toLowerCase()] =
            safeDecode(pair.substring(eq + 1));
      }
    }
    return out;
  }

  (String host, int port) parseAuthority(String a) {
    a = a.trim();
    if (a.isEmpty) return ('', -1);
    if (a.startsWith('[')) {
      final close = a.indexOf(']');
      if (close < 0) return (a, -1);
      final host = a.substring(1, close);
      final rest = a.substring(close + 1);
      if (rest.startsWith(':')) {
        return (host, int.tryParse(rest.substring(1)) ?? -1);
      }
      return (host, -1);
    }
    final colon = a.lastIndexOf(':');
    if (colon >= 0) {
      final host = a.substring(0, colon);
      return (host, int.tryParse(a.substring(colon + 1)) ?? -1);
    }
    return (a, -1);
  }

  String decodeBase64Url(String input) {
    var s = input.trim().replaceAll('-', '+').replaceAll('_', '/');
    switch (s.length % 4) {
      case 0: break;
      case 2: s += '==';
      case 3: s += '=';
      default: throw InvalidVpnLinkTypeException(reason: 'Invalid base64 length (${s.length})', link: input);
    }
    try {
      return utf8.decode(base64.decode(s), allowMalformed: true);
    } on FormatException {
      throw InvalidVpnLinkTypeException(reason:'Invalid base64 data', link: input);
    }
  }

  VpnNodeData build({
    required ProtocolTypes protocol, 
    required String link, 
    required String name, 
    required String address, 
    required int port, 
    required String credential, 
    required Map<String, String> params
    }) {
    final trimmed = name.trim();
    return VpnNodeData(
      protocol: protocol,
      originalUrl: link,
      name: trimmed.isEmpty ? address : trimmed,
      address: address,
      port: port,
      credential: credential,
      params: params,
    );
  }
}