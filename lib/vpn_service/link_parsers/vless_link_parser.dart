part of 'link_parser.dart';

class VlessLinkParser extends LinkParserBase {
  @override
  VpnNodeData parseLink(String link) {
    final body = stripScheme(link, ProtocolTypes.vless);

    final hashIdx = body.indexOf('#');
    final fragment = hashIdx >= 0 ? body.substring(hashIdx + 1) : '';
    final mainAndQuery = hashIdx >= 0 ? body.substring(0, hashIdx) : body;

    final qIdx = mainAndQuery.indexOf('?');
    final authPart = qIdx >= 0 ? mainAndQuery.substring(0, qIdx) : mainAndQuery;
    final query = qIdx >= 0 ? mainAndQuery.substring(qIdx + 1) : '';

    final atIdx = authPart.lastIndexOf('@');
    if (atIdx <= 0) {
      throw InvalidVpnLinkTypeException(reason: 'Missing UUID in vless link', link: link);
    }
    final uuid = safeDecode(authPart.substring(0, atIdx));
    final (host, port) = parseAuthority(authPart.substring(atIdx + 1));

    if (host.isEmpty) throw InvalidVpnLinkTypeException(reason: 'Missing address in vless link', link: link);
    if (port <= 0 || port > 65535) throw InvalidVpnLinkTypeException(reason: 'Invalid port in vless link', link: link);

    final params = parseQuery(query);
    params['id'] = uuid;
    params.putIfAbsent('security', () => 'none');
    params.putIfAbsent('type', () => 'tcp');

    return build(protocol: ProtocolTypes.vless, link: link, name: decodeFragment(fragment), address: host, port: port, credential: uuid, params: params);
  }
}