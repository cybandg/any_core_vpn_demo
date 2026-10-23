part of 'vpn_key_storage_service.dart';

typedef VpnKeyDataFactory = VpnKeyData Function(Map<String, dynamic> json);

class VpnKeySerializers {
  VpnKeySerializers._();

  static final VpnKeySerializers instance = VpnKeySerializers._();

  final Map<String, VpnKeyDataFactory> _factories = {};

  void register(String keyType, VpnKeyDataFactory factory) {
    _factories[keyType] = factory;
  }

  void unregister(String keyType) => _factories.remove(keyType);

  bool isRegistered(String keyType) => _factories.containsKey(keyType);

  Iterable<String> get registeredTypes => _factories.keys;

  VpnKeyData decode(Map<String, dynamic> json) {
    final keyType = json['keyType'] as String?;
    if (keyType == null) {
      throw const UnknownVpnKeyTypeException(keyType: '<missing>');
    }
    final factory = _factories[keyType];
    if (factory == null) {
      throw UnknownVpnKeyTypeException(keyType: keyType);
    }
    return factory(json);
  }

  VpnKeyData? tryDecode(Map<String, dynamic> json) {
    try {
      return decode(json);
    } catch (_) {
      return null;
    }
  }
}