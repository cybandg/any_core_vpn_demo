import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';


abstract interface class VpnRulesStorage {
  Future<Map<String, dynamic>?> load();

  Future<void> save(Map<String, dynamic> data);
}

class SharedPrefsRulesStorage implements VpnRulesStorage {
  static const String storageKey = 'any_core_vpn.rules.v1';

  const SharedPrefsRulesStorage();

  @override
  Future<Map<String, dynamic>?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    return (decoded as Map).cast<String, dynamic>();
  }

  @override
  Future<void> save(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(data));
  }
}