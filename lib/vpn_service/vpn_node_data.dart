import 'package:any_core_vpn/vpn_service/link_parsers/link_parser.dart';

class VpnNodeData{
    final ProtocolTypes protocol;
    final String originalUrl;
    final String name;
    final String address;
    final int port;
    final String credential; 
    final Map<String, String> params;


    VpnNodeData( {
      required this.protocol,
      required this.originalUrl, 
      required this.name, 
      required this.address, 
      required this.port, 
      required this.credential,
      required this.params,
    });

    VpnNodeData copyWithName(String name){
      return VpnNodeData(
        protocol: protocol,
        originalUrl: originalUrl,
        name: name,
        address: address,
        port: port,
        credential: credential,
        params: params,
      );
    }
}