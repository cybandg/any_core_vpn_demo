import 'dart:async';
import 'dart:convert';

import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One user-owned core config. Stored as RAW TEXT on purpose: the whole idea
/// of connectViaConfig is "verbatim copy to the core", so we never re-serialize
/// or restructure the JSON after the sanity decode at save time.
class VpnConfigItem {
  final String id;
  final String name;
  final VpnCore core;
  final String configJson;
  final DateTime createdAt;
  final DateTime updatedAt;

  const VpnConfigItem({
    required this.id,
    required this.name,
    required this.core,
    required this.configJson,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'core': core.name,
        'configJson': configJson,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory VpnConfigItem.fromJson(Map<String, dynamic> json) => VpnConfigItem(
        id: json['id'] as String,
        name: json['name'] as String,
        core: VpnCore.values.firstWhere(
          (c) => c.name == json['core'],
          orElse: () => VpnCore.xray,
        ),
        configJson: json['configJson'] as String,
        createdAt:
            DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
                DateTime.now(),
        updatedAt:
            DateTime.tryParse(json['updatedAt']?.toString() ?? '') ??
                DateTime.now(),
      );

  VpnConfigItem copyWith({String? name, VpnCore? core, String? configJson}) =>
      VpnConfigItem(
        id: id,
        name: name ?? this.name,
        core: core ?? this.core,
        configJson: configJson ?? this.configJson,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );
}

/// App-side persistent storage for user configs.
/// SharedPreferences lives in the app data dir => survives app updates.
class VpnConfigStorageService {
  VpnConfigStorageService._();

  static final VpnConfigStorageService instance = VpnConfigStorageService._();

  static const _prefsKey = 'vpn_user_configs_v1';

  SharedPreferences? _prefs;
  List<VpnConfigItem> _items = [];
  final _controller = StreamController<List<VpnConfigItem>>.broadcast();

  List<VpnConfigItem> get configs => List.unmodifiable(_items);

  Stream<List<VpnConfigItem>> get configsStream => _controller.stream;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        _items = list
            .whereType<Map<String, dynamic>>()
            .map(VpnConfigItem.fromJson)
            .toList();
      } catch (_) {
        // Corrupt payload: start clean instead of crashing on every launch.
        _items = [];
      }
    }
    _emit();
  }

  Future<VpnConfigItem> add({
    required String name,
    required VpnCore core,
    required String configJson,
  }) async {
    final now = DateTime.now();
    final item = VpnConfigItem(
      id: 'cfg-${now.microsecondsSinceEpoch}',
      name: name,
      core: core,
      configJson: configJson,
      createdAt: now,
      updatedAt: now,
    );
    _items = [..._items, item];
    await _persist();
    return item;
  }

  Future<void> update(VpnConfigItem updated) async {
    _items = [for (final i in _items) i.id == updated.id ? updated : i];
    await _persist();
  }

  Future<void> remove(String id) async {
    _items = _items.where((i) => i.id != id).toList();
    await _persist();
  }

  Future<void> _persist() async {
    await _prefs?.setString(
      _prefsKey,
      jsonEncode(_items.map((i) => i.toJson()).toList()),
    );
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(configs);
  }
}