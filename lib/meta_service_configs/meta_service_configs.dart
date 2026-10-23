import 'package:any_core_vpn/meta_service_configs/config_storage.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/connection_mode_config.dart';

//[import new config script here]import 'package:any_core_vpn/meta_service_configs/connection_mode_config.dart'

import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';

abstract class CachingConfigValue<T>  {
  T get value => _value;
  T _value;

  late final T _defaultValue;
  late final String _key;
  late final ConfigStorage _storage;
  
  CachingConfigValue(ConfigStorage storage, {required T defaultValue, required String key}) :
    _defaultValue = defaultValue,
    _storage = storage,
    _key = key,
    _value = defaultValue;
  

  Future<void> initValue() async{
    var strValue = await _storage.initCachedValue(_key, _defaultValue.toString());
    _value = createValueFromString(strValue);
  }

  T createValueFromString(String value);

  void updateValue(T newValue){
    _storage.setCachedValue(_key, newValue.toString());
    _value = newValue;
  }
}


enum _CachingConfigKeys{
  //[register new param key here]
  sellectedConnectionMode("sellected_connection_mode"),
  sellectedVpnCore("sellected_vpn_core");
  
  final String value;
  const _CachingConfigKeys(this.value);
}


class MetaServiceConfigs{

  final ConfigStorage _configStorage;
  
  static MetaServiceConfigs get inst => _instance;
  static final MetaServiceConfigs _instance = MetaServiceConfigs._internal();

  //region register new config params here
  late ConnectionModeConfig sellectedConnectionMode;
  late VpnCoreConfig selectedVpnCore;
  //endregion

  MetaServiceConfigs._internal(): 
  _configStorage = ConfigStorage(){
    //[create new config params here]
    sellectedConnectionMode = ConnectionModeConfig(_configStorage, key: _CachingConfigKeys.sellectedConnectionMode.value);
    selectedVpnCore = VpnCoreConfig(_configStorage, key: _CachingConfigKeys.sellectedVpnCore.value);
  }

  Future<void> initMetaConfigs() async {
    await _configStorage.init();

    //[initialize new config param here]
    await sellectedConnectionMode.initValue();
    await selectedVpnCore.initValue();
  }
}