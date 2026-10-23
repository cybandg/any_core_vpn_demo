import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';

enum ConnectionMode{
  tunnel, systemProxy;

  static ConnectionMode get byDefault => systemProxy;
}

final class ConnectionModeConfig extends CachingConfigValue<ConnectionMode>{

  ConnectionModeConfig(super.storage, {required super.key}): super(defaultValue: ConnectionMode.byDefault);

  @override
  ConnectionMode createValueFromString(String value) {
    return ConnectionMode.values.firstWhere((x) => x.toString() == value, orElse: () => ConnectionMode.byDefault);
  }
}
