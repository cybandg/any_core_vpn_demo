import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';

enum VpnCore{
  xray,
  singbox;

  static VpnCore get byDefault =>singbox;
}

final class VpnCoreConfig extends CachingConfigValue<VpnCore>{

  VpnCoreConfig(super.storage, {required super.key}): super(defaultValue: VpnCore.byDefault);

  @override
  VpnCore createValueFromString(String value) {
    return VpnCore.values.firstWhere((x) => x.toString() == value, orElse: () => VpnCore.byDefault);
  }
}