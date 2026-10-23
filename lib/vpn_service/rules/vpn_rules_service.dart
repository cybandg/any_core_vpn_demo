import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:any_core_vpn/vpn_service/config_builders/core_config_builder.dart';
import 'package:any_core_vpn/vpn_service/rules/vpn_builtin_presets.dart';
import 'package:any_core_vpn/vpn_service/rules/vpn_rules_storage.dart';

class VpnRulePreset {
  final String name;
  final List<RoutingRule> rules;

  /// Human-readable label. Falls back to [name] (which is the identity).
  final String? title;

  /// Shown in the preset list; carries caveats like "direct = real IP".
  final String? description;

  /// Built-in presets are shipped in code, refreshed on every launch,
  /// IMMUTABLE (edit via [VpnRulesService.copyPreset]) and never persisted.
  final bool builtIn;

  VpnRulePreset({
    required this.name,
    List<RoutingRule>? rules,
    this.title,
    this.description,
    this.builtIn = false,
  }) : rules = List<RoutingRule>.unmodifiable(rules ?? const <RoutingRule>[]);

  bool get isDefault => name == VpnRulesService.defaultPresetName;

  String get displayName => (title?.trim().isNotEmpty ?? false) ? title! : name;

  /// True when the preset can be edited/deleted. `default` stays editable:
  /// it is the user's own scratch preset, as before.
  bool get isReadOnly => builtIn;

  VpnRulePreset copyWith({
    String? name,
    List<RoutingRule>? rules,
    String? title,
    String? description,
    bool? builtIn,
  }) =>
      VpnRulePreset(
        name: name ?? this.name,
        rules: rules ?? this.rules,
        title: title ?? this.title,
        description: description ?? this.description,
        builtIn: builtIn ?? this.builtIn,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        'rules': <Map<String, dynamic>>[for (final r in rules) r.toJson()],
      };

  factory VpnRulePreset.fromJson(Map<String, dynamic> json) => VpnRulePreset(
        name: (json['name'] as String? ?? '').trim(),
        title: json['title'] as String?,
        description: json['description'] as String?,
        // Never trust `builtIn` from storage: a user preset that claims to be
        // built-in would become undeletable.
        builtIn: false,
        rules: <RoutingRule>[
          for (final raw in (json['rules'] as List? ?? const []))
            if (raw is Map) RoutingRule.fromJson(Map<String, dynamic>.from(raw)),
        ],
      );

  @override
  String toString() =>
      'VpnRulePreset($name, ${rules.length} rules, builtIn=$builtIn)';
}

enum VpnRulesChangeType {
  presetCreated,
  presetRenamed,
  presetDeleted,
  presetActivated,
  presetUpdated,
  presetCopied,
  ruleAdded,
  ruleUpdated,
  ruleRemoved,
  ruleMoved,
}

class VpnRulesChange {
  final VpnRulesChangeType type;
  final String presetName;

  final RoutingRule? rule;
  final String? ruleId;

  final int? ruleIndex;

  final String? previousName;

  final String? previousActivePreset;

  const VpnRulesChange({
    required this.type,
    required this.presetName,
    this.rule,
    this.ruleId,
    this.ruleIndex,
    this.previousName,
    this.previousActivePreset,
  });

  bool get isDefaultPreset => presetName == VpnRulesService.defaultPresetName;

  String get activePresetName => VpnRulesService.instance.activePresetName;

  bool get affectsActivePreset => activePresetName == presetName;

  bool get affectsRuntimeRouting {
    if (!affectsActivePreset) return false;
    return switch (type) {
      VpnRulesChangeType.presetCreated ||
      VpnRulesChangeType.presetRenamed ||
      VpnRulesChangeType.presetDeleted ||
      VpnRulesChangeType.presetCopied =>
        false,
      _ => true,
    };
  }

  @override
  String toString() =>
      'VpnRulesChange(${type.name}, preset: $presetName, rule: ${ruleId ?? '—'})';
}

class VpnRulesService {
  VpnRulesService._();

  static final VpnRulesService instance = VpnRulesService._();

  static void Function(String message) log = debugPrint;

  static const String defaultPresetName = 'default';

  final List<VpnRulePreset> _presets = <VpnRulePreset>[];
  String _activePresetName = defaultPresetName;

  VpnRulesStorage? _storage;
  Future<void>? _loadFuture;
  Future<void> _saveQueue = Future<void>.value();
  int _idCounter = 0;
  final Random _random = Random();

  final List<void Function(VpnRulesChange change)> _delegates =
      <void Function(VpnRulesChange)>[];
  final StreamController<VpnRulesChange> _changeController =
      StreamController<VpnRulesChange>.broadcast();

  Future<void> init({VpnRulesStorage? storage}) {
    if (storage != null) _storage = storage;
    _loadFuture ??= _load();
    return _loadFuture!;
  }

  Future<void> _ensureLoaded() {
    _loadFuture ??= _load();
    return _loadFuture!;
  }

  Future<void> _load() async {
    final VpnRulesStorage storage = _storage ??= const SharedPrefsRulesStorage();
    Map<String, dynamic>? stored;
    try {
      stored = await storage.load();
    } catch (e, st) {
      VpnRulesService.log('VpnRulesService: cannot read rules storage ($e)\n$st');
    }
    if (stored != null) _restore(stored);

    if (_find(defaultPresetName) == null) {
      _presets.insert(0, VpnRulePreset(name: defaultPresetName));
      _persist();
    }

    // Built-ins are code-owned: refresh them on every launch so curated list
    // updates reach everyone without a migration.
    _registerBuiltIns();

    if (_find(_activePresetName) == null) _activePresetName = defaultPresetName;
  }

  void _registerBuiltIns() {
    for (final builtIn in BuiltInRoutingPresets.all) {
      final existing = _find(builtIn.name);
      if (existing == null) {
        _presets.add(builtIn);
        continue;
      }
      if (existing.builtIn) {
        // Replace: the code version always wins over a stale in-memory copy.
        _presets[_presets.indexOf(existing)] = builtIn;
      }
      // A USER preset that happens to share a built-in name shadows it and is
      // left untouched (that is how "copy and tweak" survives a restart).
    }
  }

  void _restore(Map<String, dynamic> data) {
    final rawPresets = data['presets'];
    if (rawPresets is List) {
      for (final raw in rawPresets) {
        if (raw is! Map) continue;
        final preset = VpnRulePreset.fromJson(Map<String, dynamic>.from(raw));
        if (preset.name.isEmpty) continue;
        if (preset.name == defaultPresetName) {
          final existing = _find(defaultPresetName);
          if (existing != null) {
            if (existing.rules.isEmpty && preset.rules.isNotEmpty) {
              _presets[_presets.indexOf(existing)] = preset;
            }
            continue;
          }
        }
        if (_find(preset.name) != null) continue;
        _presets.add(preset);
      }
    }
    final active = data['activePreset'];
    if (active is String && active.trim().isNotEmpty) {
      _activePresetName = active.trim();
    }
    for (var i = 0; i < _presets.length; i++) {
      _presets[i] = _presets[i].copyWith(
        rules: [
          for (final r in _presets[i].rules) r.id == null ? _withGeneratedId(r) : r,
        ],
      );
    }
  }

  List<VpnRulePreset> get presets => List.unmodifiable(_presets);

  List<String> get presetNames => <String>[for (final p in _presets) p.name];

  /// User-created presets only (what the storage holds).
  List<VpnRulePreset> get userPresets =>
      List.unmodifiable(_presets.where((p) => !p.builtIn));

  VpnRulePreset? presetOrNull(String name) => _find(name.trim());

  VpnRulePreset preset(String name) {
    final p = _find(name.trim());
    if (p == null) {
      throw StateError('VpnRulesService: preset "${name.trim()}" not found');
    }
    return p;
  }

  VpnRulePreset get defaultPreset =>
      _find(defaultPresetName) ?? _createDefaultPresetSync();

  String get activePresetName => _activePresetName;

  VpnRulePreset get activePreset => _find(_activePresetName) ?? defaultPreset;

  /// Rules of [presetName]; falls back to the ACTIVE preset, then to default.
  /// A stale name (preset deleted on another device) degrades instead of
  /// throwing - a broken routing preset must never block connecting.
  Future<List<RoutingRule>> rulesFor([String? presetName]) async {
    await _ensureLoaded();
    final name = presetName?.trim();
    if (name == null || name.isEmpty) return activePreset.rules;
    final preset = _find(name);
    if (preset != null) return preset.rules;
    VpnRulesService.log(
        'VpnRulesService: preset "$name" not found — using "$defaultPresetName"');
    return defaultPreset.rules;
  }

  VpnRulePreset? _find(String name) {
    for (final p in _presets) {
      if (p.name == name) return p;
    }
    return null;
  }

  VpnRulePreset _createDefaultPresetSync() {
    final preset = VpnRulePreset(name: defaultPresetName);
    _presets.insert(0, preset);
    _persist();
    _notify(VpnRulesChangeType.presetCreated, defaultPresetName);
    return preset;
  }

  /// Throws for built-ins: they are code-owned and immutable.
  /// Use [copyPreset] to get an editable copy.
  void _assertEditable(VpnRulePreset preset) {
    if (!preset.builtIn) return;
    throw StateError(
      'VpnRulesService: preset "${preset.name}" is built-in and read-only. '
      'Use copyPreset() to create an editable copy.',
    );
  }

  Future<VpnRulePreset> createPreset({String? name, List<RoutingRule>? rules}) async {
    await _ensureLoaded();
    final resolved = name?.trim();
    if (resolved == null || resolved.isEmpty) {
      final preset = defaultPreset;
      if (rules != null) await updatePresetRules(preset.name, rules);
      return defaultPreset;
    }
    if (_find(resolved) != null) {
      throw StateError('VpnRulesService: preset "$resolved" already exists');
    }
    final preset = VpnRulePreset(name: resolved, rules: _ensureIds(rules ?? const []));
    _presets.add(preset);
    _persist();
    _notify(VpnRulesChangeType.presetCreated, resolved);
    return preset;
  }

  /// Forks any preset (built-in or user) into an editable user preset.
  /// [newName] must be free; rule ids are regenerated so both copies stay
  /// independently editable.
  Future<VpnRulePreset> copyPreset(String sourceName, String newName) async {
    await _ensureLoaded();
    final source = _find(sourceName.trim());
    if (source == null) {
      throw StateError('VpnRulesService: preset "$sourceName" not found');
    }
    final resolved = newName.trim();
    if (resolved.isEmpty) {
      throw ArgumentError.value(newName, 'newName', 'must not be empty');
    }
    if (_find(resolved) != null) {
      throw StateError('VpnRulesService: preset "$resolved" already exists');
    }

    final copy = VpnRulePreset(
      name: resolved,
      title: source.title ?? source.displayName,
      description: source.description,
      rules: [for (final r in source.rules) _withGeneratedId(r.copyWith(id: null))],
    );

    _presets.add(copy);
    _persist();
    _notify(VpnRulesChangeType.presetCopied, resolved);
    return copy;
  }

  Future<void> renamePreset(String name, String newName) async {
    await _ensureLoaded();
    final oldName = name.trim();
    final resolved = newName.trim();
    if (resolved.isEmpty) {
      throw ArgumentError.value(newName, 'newName', 'must not be empty');
    }
    if (oldName == defaultPresetName) {
      throw StateError('VpnRulesService: "$defaultPresetName" preset cannot be renamed');
    }
    final preset = _find(oldName);
    if (preset == null) throw StateError('VpnRulesService: preset "$oldName" not found');
    _assertEditable(preset);
    if (resolved == oldName) return;
    if (_find(resolved) != null) {
      throw StateError('VpnRulesService: preset "$resolved" already exists');
    }
    _presets[_presets.indexOf(preset)] = preset.copyWith(name: resolved);
    if (_activePresetName == oldName) _activePresetName = resolved;
    _persist();
    _notify(VpnRulesChangeType.presetRenamed, resolved, previousName: oldName);
  }

  /// Returns `false` when the preset does not exist, is [defaultPresetName],
  /// or is built-in.
  Future<bool> deletePreset(String name) async {
    await _ensureLoaded();
    final trimmed = name.trim();
    if (trimmed == defaultPresetName) {
      VpnRulesService.log('VpnRulesService: "$defaultPresetName" preset cannot be deleted');
      return false;
    }
    final preset = _find(trimmed);
    if (preset == null) return false;
    if (preset.builtIn) {
      VpnRulesService.log(
          'VpnRulesService: "${preset.name}" is built-in and cannot be deleted');
      return false;
    }
    _presets.remove(preset);
    _persist();
    _notify(VpnRulesChangeType.presetDeleted, trimmed);
    if (_activePresetName == trimmed) {
      _activePresetName = defaultPresetName;
      _persist();
      _notify(VpnRulesChangeType.presetActivated, defaultPresetName,
          previousActivePreset: trimmed);
    }
    return true;
  }

  Future<void> activatePreset(String name) async {
    await _ensureLoaded();
    final trimmed = name.trim();
    final preset = _find(trimmed);
    if (preset == null) {
      throw StateError('VpnRulesService: preset "$trimmed" not found');
    }
    if (_activePresetName == trimmed) return;
    final previous = _activePresetName;
    _activePresetName = trimmed;
    _persist();
    _notify(VpnRulesChangeType.presetActivated, trimmed,
        previousActivePreset: previous);
  }

  Future<void> updatePresetRules(String name, List<RoutingRule> rules) async {
    await _ensureLoaded();
    final trimmed = name.trim().isEmpty ? defaultPresetName : name.trim();
    final preset = _find(trimmed);
    if (preset == null) {
      throw StateError('VpnRulesService: preset "$trimmed" not found');
    }
    _assertEditable(preset);
    _replacePresetRules(preset, _ensureIds(rules));
    _persist();
    _notify(VpnRulesChangeType.presetUpdated, trimmed);
  }

  Future<RoutingRule> addRule(RoutingRule rule, {String? presetName}) async {
    await _ensureLoaded();
    final preset = _resolveForWrite(presetName);
    _assertEditable(preset);
    final stored = rule.id != null ? rule : _withGeneratedId(rule);
    final rules = [...preset.rules, stored];
    _replacePresetRules(preset, rules);
    _persist();
    _notify(VpnRulesChangeType.ruleAdded, preset.name,
        rule: stored, ruleId: stored.id, ruleIndex: rules.length - 1);
    return stored;
  }

  Future<bool> updateRule(String ruleId, RoutingRule rule, {String? presetName}) async {
    await _ensureLoaded();
    final preset = _resolveForWrite(presetName);
    _assertEditable(preset);
    final index = preset.rules.indexWhere((r) => r.id == ruleId);
    if (index < 0) {
      VpnRulesService.log('VpnRulesService: rule "$ruleId" not found in "${preset.name}"');
      return false;
    }
    final stored = rule.copyWith(id: ruleId);
    final rules = [...preset.rules]..[index] = stored;
    _replacePresetRules(preset, rules);
    _persist();
    _notify(VpnRulesChangeType.ruleUpdated, preset.name,
        rule: stored, ruleId: ruleId, ruleIndex: index);
    return true;
  }

  Future<bool> removeRule(String ruleId, {String? presetName}) async {
    await _ensureLoaded();
    final preset = _resolveForWrite(presetName);
    _assertEditable(preset);
    final index = preset.rules.indexWhere((r) => r.id == ruleId);
    if (index < 0) return false;
    final removed = preset.rules[index];
    final rules = [...preset.rules]..removeAt(index);
    _replacePresetRules(preset, rules);
    _persist();
    _notify(VpnRulesChangeType.ruleRemoved, preset.name,
        rule: removed, ruleId: ruleId, ruleIndex: index);
    return true;
  }

  Future<void> moveRule(String ruleId, int newIndex, {String? presetName}) async {
    await _ensureLoaded();
    final preset = _resolveForWrite(presetName);
    _assertEditable(preset);
    final index = preset.rules.indexWhere((r) => r.id == ruleId);
    if (index < 0) return;
    final clamped = newIndex.clamp(0, preset.rules.length - 1);
    if (clamped == index) return;
    final rules = [...preset.rules];
    final rule = rules.removeAt(index);
    rules.insert(clamped, rule);
    _replacePresetRules(preset, rules);
    _persist();
    _notify(VpnRulesChangeType.ruleMoved, preset.name,
        rule: rule, ruleId: rule.id, ruleIndex: clamped);
  }

  /// Convenience toggle used by the rules list switch.
  Future<bool> setRuleEnabled(
    String ruleId,
    bool enabled, {
    String? presetName,
  }) async {
    final preset = _resolveForWrite(presetName);
    final index = preset.rules.indexWhere((r) => r.id == ruleId);
    if (index < 0) return false;
    final current = preset.rules[index];
    if (current.enabled == enabled) return true;
    return updateRule(ruleId, current.copyWith(enabled: enabled),
        presetName: presetName);
  }

  void addRulesDelegate(void Function(VpnRulesChange change) delegate) {
    if (!_delegates.contains(delegate)) _delegates.add(delegate);
  }

  void removeRulesDelegate(void Function(VpnRulesChange change) delegate) {
    _delegates.remove(delegate);
  }

  Stream<VpnRulesChange> get changes => _changeController.stream;

  void _notify(
    VpnRulesChangeType type,
    String presetName, {
    RoutingRule? rule,
    String? ruleId,
    int? ruleIndex,
    String? previousName,
    String? previousActivePreset,
  }) {
    final change = VpnRulesChange(
      type: type,
      presetName: presetName,
      rule: rule,
      ruleId: ruleId,
      ruleIndex: ruleIndex,
      previousName: previousName,
      previousActivePreset: previousActivePreset,
    );
    for (final delegate in List.of(_delegates)) {
      try {
        delegate(change);
      } catch (e, st) {
        VpnRulesService.log('VpnRulesService: delegate error ($e)\n$st');
      }
    }
    _changeController.add(change);
  }

  VpnRulePreset _resolveForWrite(String? presetName) {
    final name = presetName?.trim();
    if (name == null || name.isEmpty) return defaultPreset;
    final preset = _find(name);
    if (preset == null) {
      throw StateError('VpnRulesService: preset "$name" not found');
    }
    return preset;
  }

  void _replacePresetRules(VpnRulePreset preset, List<RoutingRule> rules) {
    // copyWith preserves title/description/builtIn - rebuilding by hand here
    // used to silently drop them.
    _presets[_presets.indexOf(preset)] = preset.copyWith(rules: rules);
  }

  List<RoutingRule> _ensureIds(List<RoutingRule> rules) =>
      [for (final r in rules) r.id != null ? r : _withGeneratedId(r)];

  RoutingRule _withGeneratedId(RoutingRule rule) => rule.copyWith(id: _generateId());

  String _generateId() {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    _idCounter++;
    return 'r-$stamp-${_idCounter.toRadixString(36)}-${_random.nextInt(1 << 32).toRadixString(36)}';
  }

  void _persist() {
    final storage = _storage;
    if (storage == null) return;
    final snapshot = _snapshot();
    _saveQueue = _saveQueue.then((_) => storage.save(snapshot)).catchError((Object e) {
      VpnRulesService.log('VpnRulesService: cannot persist rules ($e)');
    });
  }

  /// Built-ins are excluded: they are regenerated from code on every launch,
  /// persisting them would freeze stale curated lists forever.
  Map<String, dynamic> _snapshot() => <String, dynamic>{
        'version': 1,
        'activePreset': _activePresetName,
        'presets': <Map<String, dynamic>>[
          for (final p in _presets)
            if (!p.builtIn) p.toJson(),
        ],
      };

  //----- testing block ------

  @visibleForTesting
  static void resetForTesting() {
    final inst = instance;
    inst._presets.clear();
    inst._activePresetName = defaultPresetName;
    inst._loadFuture = null;
    inst._saveQueue = Future<void>.value();
    inst._idCounter = 0;
    inst._delegates.clear();
    inst._storage = null;
  }

  @visibleForTesting
  Future<void> debugWaitForPersist() async {
    await _saveQueue;
  }
  //--------------------------
}