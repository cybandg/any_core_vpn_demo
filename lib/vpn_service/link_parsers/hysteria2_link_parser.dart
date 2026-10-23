part of 'link_parser.dart';

class Hysteria2LinkParser extends LinkParserBase {
  @override
  VpnNodeData parseLink(String link) {
    final body = stripScheme(link, ProtocolTypes.hysteria2);

    final hashIdx = body.indexOf('#');
    final fragment = hashIdx >= 0 ? body.substring(hashIdx + 1) : '';
    final mainAndQuery = hashIdx >= 0 ? body.substring(0, hashIdx) : body;

    final qIdx = mainAndQuery.indexOf('?');
    final authPart = qIdx >= 0 ? mainAndQuery.substring(0, qIdx) : mainAndQuery;
    final query = qIdx >= 0 ? mainAndQuery.substring(qIdx + 1) : '';

    final atIdx = authPart.lastIndexOf('@');
    if (atIdx <= 0) {
      throw InvalidVpnLinkTypeException(
        reason: 'Missing auth/password in Hysteria 2 link',
        link: link,
      );
    }

    final password = safeDecode(authPart.substring(0, atIdx));
    final (host, port) = parseAuthority(authPart.substring(atIdx + 1));

    if (host.isEmpty) {
      throw InvalidVpnLinkTypeException(reason: 'Missing address in Hysteria 2 link', link: link);
    }
    // Hysteria 2 operates on UDP, default is 443 if omitted
    final effectivePort = port <= 0 ? 443 : port;

    final params = parseQuery(query);
    params['password'] = password;
    params.putIfAbsent('sni', () => host);
    params.putIfAbsent('security', () => 'tls');

    // Поддержка параметров obfs и скоростей (up/down)
    if (params.containsKey('obfs-password')) {
      params['obfs_password'] = params['obfs-password']!;
    }

    return build(
      protocol: ProtocolTypes.hysteria2,
      link: link,
      name: decodeFragment(fragment),
      address: host,
      port: effectivePort,
      credential: password,
      params: params,
    );
  }
}
