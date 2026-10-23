library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:any_core_vpn/vpn_service/exceptions/vpn_service_exception.dart';
import 'package:any_core_vpn/vpn_service/link_parsers/link_parser.dart';
import 'package:any_core_vpn/vpn_service/vpn_node_data.dart';

part 'vpn_key_data.dart';
part 'vpn_key_serializers.dart';
part 'vpn_link_key_data.dart';

typedef VpnKeyLinkBuilder = FutureOr<VpnKeyData> Function(VpnNodeData node);

class VpnKeyStorageService {
  VpnKeyStorageService._({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                migrateOnAlgorithmChange: true, 
              ),
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              mOptions: MacOsOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              wOptions: WindowsOptions(
                useBackwardCompatibility: false, 
              ),
            );

  static VpnKeyStorageService? _instance;

  static VpnKeyStorageService get instance => _instance ??= VpnKeyStorageService._();

  static const String _storageKey = 'vpn_key_storage_v1';
  static const String _defaultBuilderKey = '*';

  final FlutterSecureStorage _storage;
  final Map<String, VpnKeyData> _keys = {};
  final List<Map<String, dynamic>> _unknownRaw = [];
  final Map<String, VpnKeyLinkBuilder> _linkBuilders = {};
  final StreamController<List<VpnKeyData>> _changesController =
      StreamController<List<VpnKeyData>>.broadcast();

  bool _initialized = false;

  Stream<List<VpnKeyData>> get keysStream => _changesController.stream;

  List<VpnKeyData> get allKeys {
    final keys = _keys.values.toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return UnmodifiableListView(keys);
  }

  Future<void> init() async {
    if (_initialized) return;
    VpnKeySerializers.instance
        .register(VpnLinkKeyData.keyTypeName, VpnLinkKeyData.fromJson);
    await _readFromDisk();
    _initialized = true;
  }

  Future<List<VpnKeyData>> loadKeys({bool force = false}) async {
    if (!_initialized || force) {
      await init();
      if (force) await _readFromDisk();
    }
    return allKeys;
  }

  VpnKeyData? findKey(String id) => _keys[id];

  List<VpnKeyData> keysByProtocol(ProtocolTypes protocol) =>
      allKeys.where((k) => k.protocol == protocol).toList();

  List<VpnKeyData> keysByName(
    String name, {
    bool exact = false,
    bool caseSensitive = false,
  }) {
    return query(
      nameEquals: exact ? name : null,
      nameContains: exact ? null : name,
      caseSensitive: caseSensitive,
    );
  }

  List<VpnKeyData> query({
    ProtocolTypes? protocol,
    String? nameContains,
    String? nameEquals,
    bool caseSensitive = false,
  }) {
    return allKeys.where((key) {
      if (protocol != null && key.protocol != protocol) return false;
      final keyName = caseSensitive ? key.name : key.name.toLowerCase();
      if (nameEquals != null) {
        final target = caseSensitive ? nameEquals : nameEquals.toLowerCase();
        if (keyName != target) return false;
      }
      if (nameContains != null) {
        final target =
            caseSensitive ? nameContains : nameContains.toLowerCase();
        if (!keyName.contains(target)) return false;
      }
      return true;
    }).toList();
  }

  void registerLinkBuilder(ProtocolTypes protocol, VpnKeyLinkBuilder builder) {
    _linkBuilders[protocol.name] = builder;
  }

  void registerDefaultLinkBuilder(VpnKeyLinkBuilder builder) {
    _linkBuilders[_defaultBuilderKey] = builder;
  }

  Future<VpnKeyData> buildKeyFromLink(String link) async {
    final node = LinkParser.createParserForLink(link).parseLink(link);
    final builder = _linkBuilders[node.protocol.name] ??
        _linkBuilders[_defaultBuilderKey] ??
        _defaultLinkBuilder;
    return builder(node);
  }

  Future<VpnKeyData> addFromLink(String link, {bool replace = true}) async {
    await init();
    final key = await buildKeyFromLink(link);
    return addKey(key, replace: replace);
  }

  Future<List<VpnKeyData>> addFromLinks(
    Iterable<String> links, {
    bool replace = true,
    bool skipInvalid = false,
  }) async {
    await init();
    final result = <VpnKeyData>[];
    for (final link in links) {
      try {
        result.add(await addFromLink(link, replace: replace));
      } catch (_) {
        if (!skipInvalid) rethrow;
      }
    }
    return result;
  }

  Future<VpnKeyData> addKey(VpnKeyData key, {bool replace = true}) async {
    await init();
    if (_keys.containsKey(key.id) && !replace) {
      throw VpnKeyAlreadyExistsException(id: key.id);
    }
    if (!VpnKeySerializers.instance.isRegistered(key.keyType)) {
      throw UnknownVpnKeyTypeException(keyType: key.keyType);
    }
    _unknownRaw.removeWhere((raw) => raw['id'] == key.id);
    _keys[key.id] = key;
    await _persist();
    return key;
  }

  Future<List<VpnKeyData>> addKeys(
    Iterable<VpnKeyData> keys, {
    bool replace = true,
  }) async {
    await init();
    final result = <VpnKeyData>[];
    for (final key in keys) {
      result.add(await addKey(key, replace: replace));
    }
    return result;
  }

  Future<VpnKeyData> renameKey(String id, String newName) async {
    await init();
    final key = _keys[id];
    if (key == null) throw VpnKeyNotFoundException(id: id);
    final renamed = key.copyWithName(newName);
    _keys[id] = renamed;
    await _persist();
    return renamed;
  }

  Future<bool> removeKey(String id) async {
    await init();
    final removed = _keys.remove(id) != null;
    final rawBefore = _unknownRaw.length;
    _unknownRaw.removeWhere((raw) => raw['id'] == id);
    final rawRemoved = _unknownRaw.length != rawBefore;
    if (removed || rawRemoved) await _persist();
    return removed || rawRemoved;
  }

  Future<int> removeWhere(bool Function(VpnKeyData key) test) async {
    await init();
    final ids = _keys.values.where(test).map((k) => k.id).toList();
    for (final id in ids) {
      _keys.remove(id);
    }
    if (ids.isNotEmpty) await _persist();
    return ids.length;
  }

  Future<int> removeByProtocol(ProtocolTypes protocol) =>
      removeWhere((k) => k.protocol == protocol);

  Future<void> clear() async {
    await init();
    _keys.clear();
    _unknownRaw.clear();
    await _persist();
  }

  Future<void> dispose() async {
    await _changesController.close();
    _instance = null;
    _initialized = false;
  }

  Future<void> _readFromDisk() async {
    _keys.clear();
    _unknownRaw.clear();
    final raw = await _storage.read(key: _storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final key = VpnKeySerializers.instance.tryDecode(map);
        if (key == null) {
          _unknownRaw.add(map);
        } else {
          _keys[key.id] = key;
        }
      }
    } catch (_) {
      return;
    }
  }

  Future<void> _persist() async {
    final payload = [
      ..._keys.values.map((k) => k.toJson()),
      ..._unknownRaw,
    ];
    await _storage.write(key: _storageKey, value: jsonEncode(payload));
    if (!_changesController.isClosed) {
      _changesController.add(allKeys);
    }
  }

  static VpnKeyData _defaultLinkBuilder(VpnNodeData node) =>
      VpnLinkKeyData(node: node);
}