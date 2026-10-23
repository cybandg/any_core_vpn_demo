import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:any_core_vpn/meta_service_configs/specific_configs/connection_mode_config.dart';
import 'package:any_core_vpn_example/config_store/configs_screen.dart';
import 'package:any_core_vpn_example/config_store/vpn_config_storage_service.dart';
import 'package:any_core_vpn_example/config_viewer/config_viewer_screen.dart';
import 'package:any_core_vpn_example/macos_privilege/macos_privilege_card.dart';
import 'package:flutter/material.dart';
import 'package:any_core_vpn/key_storage_service/vpn_key_storage_service.dart';
import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/exceptions/vpn_service_exception.dart';
import 'package:any_core_vpn/vpn_service/realisations/android/android_vpn_service.dart';
import 'package:any_core_vpn/vpn_service/realisations/macos/macos_vpn_service.dart';
import 'package:any_core_vpn/vpn_service/rules/vpn_rules_service.dart';
import 'package:any_core_vpn/vpn_service/vpn_service.dart';
import 'package:any_core_vpn_example/vpn_keys_list/vpn_keys_sheet.dart';

import 'package:any_core_vpn/vpn_service/realisations/windows/windows_vpn_service.dart';

import 'vpn_rules_editor/routing_screen.dart';

/// Where the Connect button takes its payload from.
enum _ConnectSource { key, config }

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  VpnService vpnService;

  if (Platform.isAndroid) {
    vpnService = AndroidVpnService();
  } else if (Platform.isMacOS) {
    vpnService = MacOSVpnService();
  } else if (Platform.isWindows) {
    vpnService = WindowsVpnService();
  } else {
    throw UnimplementedError();
  }

  Object? initError;

  try {
    await vpnService.init();
  } catch (error, stack) {
    initError = error;
    debugPrint('$error\n$stack');
    _dumpStartupError(error, stack);
  }

  try {
    await VpnKeyStorageService.instance.init();
  } catch (error, stack) {
    initError ??= error;
    debugPrint('$error\n$stack');
  }

  try {
    await VpnConfigStorageService.instance.init();
  } catch (error, stack) {
    initError ??= error;
    debugPrint('$error\n$stack');
  }

  runApp(VpnTestApp(vpnService: vpnService, initError: initError));
}

void _dumpStartupError(Object error, StackTrace stack) {
  if (!Platform.isWindows) {
    return;
  }

  try {
    final local = Platform.environment['LOCALAPPDATA'];

    if (local == null || local.isEmpty) {
      return;
    }

    final dir = Directory('$local\\any_core_vpn');
    dir.createSync(recursive: true);

    File('${dir.path}\\startup_error.txt').writeAsStringSync(
      '${DateTime.now().toIso8601String()}\n$error\n$stack\n',
    );
  } catch (_) {}
}

class VpnTestApp extends StatelessWidget {
  final VpnService vpnService;
  final Object? initError;

  const VpnTestApp({required this.vpnService, this.initError, super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VPN Test',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: VpnTestScreen(vpnService: vpnService, initError: initError),
    );
  }
}

class VpnTestScreen extends StatefulWidget {
  final VpnService vpnService;
  final Object? initError;

  const VpnTestScreen({required this.vpnService, this.initError, super.key});

  @override
  State<VpnTestScreen> createState() => _VpnTestScreenState();
}

class _VpnTestScreenState extends State<VpnTestScreen> {
  final _keyController = TextEditingController();

  VpnService get _vpn => widget.vpnService;
  VpnKeyStorageService get _keyStorage => VpnKeyStorageService.instance;

  StreamSubscription<String>? _logSub;
  StreamSubscription<List<VpnKeyData>>? _keysSub;
  StreamSubscription<List<VpnConfigItem>>? _configsSub;
  Timer? _pollTimer;

  Timer? _reconnectDebounce;

  /// What the last SUCCESSFUL connect used; auto-reconnect replays exactly it.
  String? _lastLink;
  String? _lastConfigId;

  bool _busy = false;
  bool _connected = false;
  int _savedKeysCount = 0;
  int _savedConfigsCount = 0;
  final List<String> _logs = [];

  _ConnectSource _source = _ConnectSource.key;
  String? _selectedConfigId;

  VpnCoreConfig get _selectedCore => MetaServiceConfigs.inst.selectedVpnCore;
  ConnectionModeConfig get _selectedConnectionMode =>
      MetaServiceConfigs.inst.sellectedConnectionMode;

  void _append(String line) {
    if (!mounted) return;
    setState(() {
      _logs.add(line);
      if (_logs.length > 300) _logs.removeRange(0, _logs.length - 300);
    });
  }

  void _onRulesChanged(VpnRulesChange change) {
    if (mounted) setState(() {});

    if (!change.affectsRuntimeRouting) return;

    if (!_connected) {
      _append(
        '· routing updated (${change.type.name}) — applied on next connect',
      );
      return;
    }
    _append(
      '· routing updated (${change.type.name}) — auto-reconnect scheduled',
    );
    _reconnectDebounce?.cancel();
    _reconnectDebounce = Timer(
      const Duration(milliseconds: 800),
      _autoReconnect,
    );
  }

  Future<void> _autoReconnect() async {
    if (!_connected) return;
    if (_busy) {
      _reconnectDebounce = Timer(
        const Duration(milliseconds: 800),
        _autoReconnect,
      );
      return;
    }

    setState(() => _busy = true);
    try {
      _append(
        '--- auto-reconnect: rebuilding connection with updated rules ---',
      );
      await _vpn.disconnect();

      final link = _lastLink;
      if (link != null) {
        await _vpn.connect(link);
        return;
      }

      final configId = _lastConfigId;
      final item = configId == null ? null : _configById(configId);
      if (item == null) {
        _append('!! auto-reconnect: last config is gone from storage');
        return;
      }
      // Re-read from storage on purpose: edits made on the configs screen
      // between the connect and the reconnect must apply.
      await _connectViaConfigItem(item);
    } catch (e) {
      _append('!! auto-reconnect failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchCore(VpnCore core) async {
    if (core == _selectedCore.value) return;

    if (_connected || _busy) {
      _append('--- switching core: disconnecting current tunnel ---');
      setState(() => _busy = true);
      try {
        await _vpn.disconnect();
      } catch (e) {
        _append('!! disconnect error: $e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }

    setState(() {
      MetaServiceConfigs.inst.selectedVpnCore.updateValue(core);
    });
    _append('=== core switched to: ${core.name} ===');
  }

  Future<void> _switchMode(ConnectionMode mode) async {
    if (mode == _selectedConnectionMode.value) return;

    if (_connected || _busy) {
      _append(
        '--- switching connection mode: disconnecting current connection ---',
      );
      setState(() => _busy = true);
      try {
        await _vpn.disconnect();
      } catch (e) {
        _append('!! disconnect error: $e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }

    setState(() {
      MetaServiceConfigs.inst.sellectedConnectionMode.updateValue(mode);
    });
    _append('=== core switched to: ${mode.name} ===');
  }

  Future<void> _toggleConnection() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_connected) {
        _append('--- disconnecting ---');
        await _vpn.disconnect();
        return;
      }

      if (_source == _ConnectSource.key) {
        final key = _keyController.text.trim();
        if (key.isEmpty) {
          _append('!! key is empty');
          return;
        }

        _append('--- connecting via ${_selectedCore.value.name} ---');
        try {
          await _vpn.connect(key);
        } on PermissionDeniedException catch (_) {
          _append('!! VPN permission denied');
          return;
        } catch (e) {
          _append(e.toString());
          return;
        }

        _lastLink = key;
        _lastConfigId = null;
        return;
      }

      // ---- config source: verbatim connect through the shared path ----
      final item = _selectedConfigItem();
      if (item == null) {
        _append('!! no config selected — pick one or create it in My configs');
        return;
      }

      _append(
        '--- connecting via config "${item.name}" (${item.core.name}) ---',
      );
      try {
        await _connectViaConfigItem(item);
      } on PermissionDeniedException catch (_) {
        _append('!! VPN permission denied');
        return;
      } catch (e) {
        _append(e.toString());
        return;
      }

      _lastConfigId = item.id;
      _lastLink = null;
    } catch (e, st) {
      _append('!! error: $e');
      debugPrint('$e\n$st');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  VpnConfigItem? _configById(String id) {
    for (final config in VpnConfigStorageService.instance.configs) {
      if (config.id == id) return config;
    }
    return null;
  }

  VpnConfigItem? _selectedConfigItem() =>
      _selectedConfigId == null ? null : _configById(_selectedConfigId!);

  /// connectViaConfig trusts the caller: the config must be fed to the core it
  /// was written for. Android reads the core from the global selection, so
  /// align the selection with the stored config (same as the configs screen).
  /// macOS detects the core from the config shape itself; this is harmless there.
  Future<void> _connectViaConfigItem(VpnConfigItem item) async {
    if (MetaServiceConfigs.inst.selectedVpnCore.value != item.core) {
      MetaServiceConfigs.inst.selectedVpnCore.updateValue(item.core);
    }
    final config = jsonDecode(item.configJson) as Map<String, dynamic>;
    await _vpn.connectViaConfig(config);
  }

  Future<void> _saveCurrentLink() async {
    final link = _keyController.text.trim();
    if (link.isEmpty) {
      _append('!! nothing to save — key field is empty');
      return;
    }
    try {
      final saved = await _keyStorage.addFromLink(link);
      _append('=== key saved: "${saved.name}" (id: ${saved.id}) ===');
      final node = saved is VpnLinkKeyData ? saved.node : null;
      if (node != null) {
        _append(
          '    protocol: ${node.protocol.name}, '
          'address: ${node.address}:${node.port}',
        );
      }
    } catch (e) {
      _append('!! save failed: $e');
    }
  }

  /*
  Future<void> _resetWindowsNetworkSettings({bool hard = false}) async {
    final vpn = _vpn;

    if (vpn is! WindowsVpnService) {
      _append('!! network reset is available on Windows only');
      return;
    }

    setState(() => _busy = true);
    try {
      final result = await vpn.resetNetworkSettings(hard: hard);
      _append('=== network settings reset ($result) ===');
    } catch (e) {
      _append('!! network reset failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
*/
  void _onSavedKeySelected(VpnKeyData key) {
    if (key is! VpnLinkKeyData) {
      _append('!! key type "${key.keyType}" is not connectable in this demo');
      return;
    }
    _keyController.text = key.node.originalUrl;
    _append('--- using saved key "${key.name}" ---');
    if (!_connected && !_busy) _toggleConnection();
  }

  void _openKeysSheet() {
    showVpnKeysSheet(
      context,
      storage: _keyStorage,
      onKeySelected: _onSavedKeySelected,
    );
  }

  void _openConfigViewer() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ConfigViewerScreen(service: _vpn)),
    );
  }

  void _openConfigsScreen() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ConfigsScreen(service: _vpn)));
  }

  @override
  void initState() {
    super.initState();

    _savedKeysCount = _keyStorage.allKeys.length;
    final configs = VpnConfigStorageService.instance.configs;
    _savedConfigsCount = configs.length;
    _selectedConfigId = configs.isNotEmpty ? configs.first.id : null;

    final error = widget.initError;
    if (error != null) {
      _append('!! init failed: $error');
    }
    _keysSub = _keyStorage.keysStream.listen((keys) {
      if (!mounted) return;
      setState(() => _savedKeysCount = keys.length);
    });
    _configsSub = VpnConfigStorageService.instance.configsStream.listen((cfgs) {
      if (!mounted) return;
      setState(() {
        _savedConfigsCount = cfgs.length;
        // Drop a selection that no longer exists (deleted on configs screen).
        if (_selectedConfigId != null &&
            !cfgs.any((c) => c.id == _selectedConfigId)) {
          _selectedConfigId = cfgs.isNotEmpty ? cfgs.first.id : null;
        }
      });
    });

    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final running = await _vpn.isRunning();
        if (mounted && running != _connected) {
          setState(() => _connected = running);
        }
      } catch (_) {
        /* engine not ready yet */
      }
    });

    VpnRulesService.instance.addRulesDelegate(_onRulesChanged);
  }

  @override
  void dispose() {
    VpnRulesService.instance.removeRulesDelegate(_onRulesChanged);
    _reconnectDebounce?.cancel();
    _logSub?.cancel();
    _keysSub?.cancel();
    _configsSub?.cancel();
    _pollTimer?.cancel();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rules = VpnRulesService.instance;
    final configs = VpnConfigStorageService.instance.configs;

    return Scaffold(
      appBar: AppBar(title: const Text('sing-box / Xray test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<VpnCore>(
                segments: const [
                  ButtonSegment(
                    value: VpnCore.singbox,
                    label: Text('sing-box'),
                    icon: Icon(Icons.router),
                  ),
                  ButtonSegment(
                    value: VpnCore.xray,
                    label: Text('Xray'),
                    icon: Icon(Icons.bolt),
                  ),
                ],
                selected: {_selectedCore.value},
                onSelectionChanged: (selection) => _switchCore(selection.first),
              ),
              const SizedBox(height: 8),
              SegmentedButton<ConnectionMode>(
                segments: const [
                  ButtonSegment(
                    value: ConnectionMode.systemProxy,
                    label: Text('system proxy'),
                    icon: Icon(Icons.router),
                  ),
                  ButtonSegment(
                    value: ConnectionMode.tunnel,
                    label: Text('tunnel'),
                    icon: Icon(Icons.bolt),
                  ),
                ],
                selected: {_selectedConnectionMode.value},
                onSelectionChanged: (selection) => _switchMode(selection.first),
              ),
              const SizedBox(height: 8),
              // WHAT we connect with: a share link or a stored verbatim config.
              SegmentedButton<_ConnectSource>(
                segments: const [
                  ButtonSegment(
                    value: _ConnectSource.key,
                    label: Text('key'),
                    icon: Icon(Icons.key, size: 18),
                  ),
                  ButtonSegment(
                    value: _ConnectSource.config,
                    label: Text('config'),
                    icon: Icon(Icons.edit_note, size: 18),
                  ),
                ],
                selected: {_source},
                onSelectionChanged: (selection) =>
                    setState(() => _source = selection.first),
              ),
              const SizedBox(height: 16),
              if (_source == _ConnectSource.key) ...[
                TextField(
                  controller: _keyController,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Config key / share link',
                    hintText:
                        'vless://...  vmess://...  trojan://...  ss://...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _selectedConfigId,
                        hint: const Text('select a saved config'),
                        items: [
                          for (final config in configs)
                            DropdownMenuItem(
                              value: config.id,
                              child: Text(
                                '${config.name} (${config.core.name})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (id) =>
                            setState(() => _selectedConfigId = id),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Manage configs',
                      onPressed: _openConfigsScreen,
                      icon: const Icon(Icons.edit_note),
                    ),
                  ],
                ),
                if (configs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'No saved configs yet — create one in My configs.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _toggleConnection,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_connected ? Icons.stop : Icons.play_arrow),
                label: Text(
                  _connected
                      ? 'Disconnect'
                      : (_busy
                            ? 'Working…'
                            : (_source == _ConnectSource.key
                                  ? 'Connect'
                                  : 'Connect config')),
                ),
              ),
              const SizedBox(height: 8),
              if (_source == _ConnectSource.key)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _saveCurrentLink,
                        icon: const Icon(Icons.save_outlined, size: 18),
                        label: const Text('Save key'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _openKeysSheet,
                        icon: const Icon(Icons.key, size: 18),
                        label: Text('Keys ($_savedKeysCount)'),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    _connected ? Icons.shield : Icons.shield_outlined,
                    size: 18,
                    color: _connected ? Colors.green : scheme.outline,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _connected
                        ? 'Status: connected (${_selectedCore.value.name})'
                        : 'Status: disconnected (${_selectedCore.value.name})',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.alt_route),
                  title: const Text('Routing rules'),
                  subtitle: Text(
                    'preset "${rules.activePresetName}" · '
                    '${rules.activePreset.rules.length} rule(s)',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RoutingScreen()),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.edit_note),
                  title: const Text('My configs'),
                  subtitle: Text(
                    'create / edit / connect with your own core configs '
                    '($_savedConfigsCount)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openConfigsScreen,
                ),
              ),
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.data_object),
                  title: const Text('Core config dump'),
                  subtitle: Text(
                    'xray_config.json · singbox_config.json '
                    '(after native patching)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openConfigViewer,
                ),
              ),
              if (Platform.isMacOS) ...[
                const SizedBox(height: 8),
                const MacosPasswordlessCard(),
              ],
              const SizedBox(height: 16),
              Text(
                'Native logs',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                height: 700,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _logs.isEmpty
                    ? const Center(child: Text('no logs yet'))
                    : ListView.builder(
                        itemCount: _logs.length,
                        itemBuilder: (_, i) => Text(
                          _logs[i],
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
