part of 'link_parser.dart';

class ShadowsocksLinkParser extends LinkParserBase {
  @override
  VpnNodeData parseLink(String link) {
    final body = stripScheme(link, ProtocolTypes.shadowsocks);

    final hashIdx = body.indexOf('#');
    final fragment = hashIdx >= 0 ? body.substring(hashIdx + 1) : '';
    final mainAndQuery = hashIdx >= 0 ? body.substring(0, hashIdx) : body;

    final qIdx = mainAndQuery.indexOf('?');
    final main = qIdx >= 0 ? mainAndQuery.substring(0, qIdx) : mainAndQuery;
    final query = qIdx >= 0 ? mainAndQuery.substring(qIdx + 1) : '';

    String method = '';
    String password = '';
    String host = '';
    int port = -1;

    final atIdx = main.lastIndexOf('@');
    if (atIdx >= 0) {
      final userinfo = main.substring(0, atIdx);
      final (h, p) = parseAuthority(main.substring(atIdx + 1));
      host = h;
      port = p;

      if (userinfo.contains(':')) {
        final c = userinfo.indexOf(':');
        method = userinfo.substring(0, c);
        password = safeDecode(userinfo.substring(c + 1));
      } else {
        final decoded = decodeBase64Url(userinfo);
        final c = decoded.indexOf(':');
        if (c < 0) throw InvalidVpnLinkTypeException(reason: 'Invalid ss userinfo', link: link);
        method = decoded.substring(0, c);
        password = decoded.substring(c + 1);
      }
    } else {
      final decoded = decodeBase64Url(main);
      final aIdx = decoded.lastIndexOf('@');
      if (aIdx < 0) throw InvalidVpnLinkTypeException(reason: 'Invalid ss body', link: link);
      final mp = decoded.substring(0, aIdx);
      final (h, p) = parseAuthority(decoded.substring(aIdx + 1));
      host = h;
      port = p;
      final c = mp.indexOf(':');
      if (c < 0) throw InvalidVpnLinkTypeException(reason: 'Invalid ss method:password', link: link);
      method = mp.substring(0, c);
      password = mp.substring(c + 1);
    }

    if (host.isEmpty) throw InvalidVpnLinkTypeException(reason: 'Missing address in ss link', link: link);
    if (port <= 0 || port > 65535) throw InvalidVpnLinkTypeException(reason: 'Invalid port in ss link', link: link);

    final params = parseQuery(query);
    if (params.containsKey('pluginOpts') || params.containsKey('pluginopts')) {
      params['plugin_opts'] = params.remove('pluginOpts') ?? params.remove('pluginopts')!;
    }
    params['method'] = method;
    params['cipher'] = method;
    params['password'] = password;

    return build(protocol: ProtocolTypes.shadowsocks, link: link, name: decodeFragment(fragment), address: host, port: port, credential: password, params: params);
  }
}