part of 'vpn_key_storage_service.dart';


class VpnLinkKeyData extends VpnKeyDataBase {
  static const String keyTypeName = 'vpn_link_key';

  final VpnNodeData node;

  @override
  final String name;

  VpnLinkKeyData({
    required this.node,
    String? name,
    String? id,
    DateTime? addedAt,
  })  : name = name ?? node.name,
        super(
          id: id ?? VpnKeyDataBase.generateId(node.originalUrl),
          addedAt: addedAt,
        );

  @override
  ProtocolTypes get protocol => node.protocol;

  @override
  String get keyType => keyTypeName;

  @override
  Map<String, dynamic> dataToJson() => {
        'originalUrl': node.originalUrl,
        'name': node.name,
        'address': node.address,
        'port': node.port,
        'credential': node.credential,
        'params': node.params,
      };

  static VpnLinkKeyData fromJson(Map<String, dynamic> json) {
    final data = Map<String, dynamic>.from(json['data'] as Map);
    final addedAtRaw = json['addedAt'] as String?;

    final node = VpnNodeData(
      protocol: protocolTypesFromName(json['protocol'] as String? ?? ''),
      originalUrl: data['originalUrl'] as String? ?? '',
      name: data['name'] as String? ?? '',
      address: data['address'] as String? ?? '',
      port: data['port'] as int? ?? -1,
      credential: data['credential'] as String? ?? '',
      params: Map<String, String>.from(data['params'] as Map? ?? {}),
    );

    return VpnLinkKeyData(
      node: node,
      name: json['name'] as String?,
      id: json['id'] as String?,
      addedAt: addedAtRaw == null ? null : DateTime.tryParse(addedAtRaw),
    );
  }

  @override
  VpnLinkKeyData copyWithName(String name) => VpnLinkKeyData(
        node: node,
        name: name,
        id: id,
        addedAt: addedAt,
      );
}