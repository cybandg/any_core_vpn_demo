part of 'link_parser.dart';

class TuicLinkParser extends LinkParserBase {
  @override
  VpnNodeData parseLink(String link) {
    final body = stripScheme(link, ProtocolTypes.tuic);

    final hashIdx = body.indexOf('#');
    final fragment = hashIdx >= 0 ? body.substring(hashIdx + 1) : '';
    final mainAndQuery = hashIdx >= 0 ? body.substring(0, hashIdx) : body;

    final qIdx = mainAndQuery.indexOf('?');
    final authPart = qIdx >= 0 ? mainAndQuery.substring(0, qIdx) : mainAndQuery;
    final query = qIdx >= 0 ? mainAndQuery.substring(qIdx + 1) : '';

    final atIdx = authPart.lastIndexOf('@');
    if (atIdx <= 0) {
      throw InvalidVpnLinkTypeException(
        reason: 'Missing credentials in TUIC link',
        link: link,
      );
    }

    final userInfo = safeDecode(authPart.substring(0, atIdx));
    String uuid = userInfo;
    String password = '';

    final colonIdx = userInfo.indexOf(':');
    if (colonIdx >= 0) {
      uuid = userInfo.substring(0, colonIdx);
      password = userInfo.substring(colonIdx + 1);
    }

    final (host, port) = parseAuthority(authPart.substring(atIdx + 1));

    if (host.isEmpty) {
      throw InvalidVpnLinkTypeException(reason: 'Missing address in TUIC link', link: link);
    }
    if (port <= 0 || port > 65535) {
      throw InvalidVpnLinkTypeException(reason: 'Invalid port in TUIC link', link: link);
    }

    final params = parseQuery(query);
    params['uuid'] = uuid;
    if (password.isNotEmpty) {
      params['password'] = password;
    }
    params.putIfAbsent('sni', () => host);
    params.putIfAbsent('congestion_control', () => 'bbr');
    params.putIfAbsent('udp_relay_mode', () => 'native');
    params.putIfAbsent('alpn', () => 'h3');

    return build(
      protocol: ProtocolTypes.tuic,
      link: link,
      name: decodeFragment(fragment),
      address: host,
      port: port,
      credential: uuid,
      params: params,
    );
  }
}