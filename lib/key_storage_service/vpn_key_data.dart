part of 'vpn_key_storage_service.dart';

///you can extend this class to make your own key data models
abstract class VpnKeyData {
  String get id;
  String get name;
  ProtocolTypes get protocol;
  DateTime get addedAt;
  String get keyType;

  Map<String, dynamic> toJson();

  VpnKeyData copyWithName(String name);
}

abstract class VpnKeyDataBase implements VpnKeyData {
  @override
  final String id;

  @override
  final DateTime addedAt;

  static int _counter = 0;

  VpnKeyDataBase({String? id, DateTime? addedAt})
      : id = id ?? generateId(),
        addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> dataToJson();

  static String generateId([String? seed]) {
    final source = seed ??
        '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';
    return _fnv1a(source);
  }

  static String _fnv1a(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'keyType': keyType,
        'name': name,
        'protocol': protocol.name,
        'addedAt': addedAt.toIso8601String(),
        'data': dataToJson(),
      };
}

ProtocolTypes protocolTypesFromName(String name) => ProtocolTypes.values
    .firstWhere((p) => p.name == name, orElse: () => ProtocolTypes.notSupported);