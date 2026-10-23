import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConfigStorage{
  Future<void>? _initFuture;
  late final SharedPreferencesWithCache cahcedPrefs;

  ConfigStorage();

  Future<void> init() {
    // Already initializing or initialized → return the same future.
    if (_initFuture != null) return _initFuture!;

    _initFuture = _doInit().catchError((Object e) {
      _initFuture = null; // allow retry after a failure
      throw e;
    });
    return _initFuture!;
  }

  Future<void> _doInit() async {
    WidgetsFlutterBinding.ensureInitialized();
    cahcedPrefs = await SharedPreferencesWithCache.create(
      cacheOptions: SharedPreferencesWithCacheOptions(),
    );
  }

  Future<String> initCachedValue(String key, String defaultValue) async {
    var value = cahcedPrefs.getString(key);
    if(value == null){
      await cahcedPrefs.setString(key, defaultValue);
    }
    return value??defaultValue;
  }

  void setCachedValue(String key, String value){
    cahcedPrefs.setString(key, value);
  }

  String getCahcedValue(String key) => cahcedPrefs.getString(key)!;
}

