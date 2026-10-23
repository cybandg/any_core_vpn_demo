import 'dart:convert';

import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/vpn_service.dart';
import 'package:flutter/material.dart';

import 'vpn_config_storage_service.dart';

/// List of user configs: create / edit / delete / connect / view.
class ConfigsScreen extends StatefulWidget {
  final VpnService service;

  const ConfigsScreen({required this.service, super.key});

  @override
  State<ConfigsScreen> createState() => _ConfigsScreenState();
}

class _ConfigsScreenState extends State<ConfigsScreen> {
  final _storage = VpnConfigStorageService.instance;
  bool _busy = false;

  Future<void> _connect(VpnConfigItem item) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // connectViaConfig trusts the caller: the config must match the core.
      // Switch the selected core to the one stored with this config.
      MetaServiceConfigs.inst.selectedVpnCore.updateValue(item.core);

      final map = jsonDecode(item.configJson) as Map<String, dynamic>;
      final ok = await widget.service.connectViaConfig(map);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? 'Connected via "${item.name}"' : 'Connect failed'),
        ),
      );
      if (ok) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connect error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(VpnConfigItem? item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ConfigEditorScreen(item: item)),
    );
  }

  Future<void> _delete(VpnConfigItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${item.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _storage.remove(item.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My configs')),
      floatingActionButton: FloatingActionButton(
        onPressed: _busy ? null : () => _edit(null),
        child: const Icon(Icons.add),
      ),
      body: StreamBuilder<List<VpnConfigItem>>(
        stream: _storage.configsStream,
        initialData: _storage.configs,
        builder: (context, snapshot) {
          final items = snapshot.data ?? const <VpnConfigItem>[];
          if (items.isEmpty) {
            return const Center(
              child: Text('No configs yet — tap + to create one'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = items[index];
              return Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: Icon(
                    item.core == VpnCore.singbox ? Icons.router : Icons.bolt,
                  ),
                  title: Text(item.name),
                  subtitle: Text(
                    '${item.core.name} · updated ${item.updatedAt.toLocal()}',
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: PopupMenuButton<String>(
                    enabled: !_busy,
                    onSelected: (value) {
                      switch (value) {
                        case 'connect':
                          _connect(item);
                        case 'edit':
                          _edit(item);
                        case 'delete':
                          _delete(item);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'connect',
                        child: ListTile(
                          leading: Icon(Icons.play_arrow),
                          title: Text('Connect'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: Icon(Icons.edit),
                          title: Text('Edit / view'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('Delete'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                  onTap: _busy ? null : () => _edit(item),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Create/edit screen. Doubles as the viewer: the JSON field is the config.
class ConfigEditorScreen extends StatefulWidget {
  /// null = create a new config.
  final VpnConfigItem? item;

  const ConfigEditorScreen({this.item, super.key});

  @override
  State<ConfigEditorScreen> createState() => _ConfigEditorScreenState();
}

class _ConfigEditorScreenState extends State<ConfigEditorScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _jsonController;
  late VpnCore _core;
  bool _saving = false;

  // Minimal starter templates so a fresh config is at least structurally sane
  // (tun inbound => tunnel mode will be derived by connectViaConfig).
  static const _xrayTemplate = '''{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "tun-in",
      "port": 0,
      "protocol": "tun",
      "settings": {"mtu": 1400}
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"}
  ]
}''';

  static const _singboxTemplate = '''{
  "log": {"level": "warning"},
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30"]
    }
  ],
  "outbounds": [
    {"type": "direct", "tag": "direct"}
  ]
}''';

  static String templateFor(VpnCore core) =>
      core == VpnCore.singbox ? _singboxTemplate : _xrayTemplate;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _core = item?.core ?? MetaServiceConfigs.inst.selectedVpnCore.value;
    _nameController = TextEditingController(text: item?.name ?? '');
    _jsonController =
        TextEditingController(text: item?.configJson ?? templateFor(_core));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _jsonController.dispose();
    super.dispose();
  }

  void _onCoreChanged(VpnCore core) {
    if (core == _core) return;
    setState(() {
      // Swap the starter template only while it is untouched;
      // never clobber user edits.
      if (_jsonController.text == templateFor(_core)) {
        _jsonController.text = templateFor(core);
      }
      _core = core;
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _snack('Name is empty');
      return;
    }
    final raw = _jsonController.text;
    try {
      // Sanity decode only — storage keeps the text VERBATIM afterwards.
      jsonDecode(raw);
    } catch (e) {
      _snack('Invalid JSON: $e');
      return;
    }

    setState(() => _saving = true);
    try {
      final storage = VpnConfigStorageService.instance;
      final item = widget.item;
      if (item == null) {
        await storage.add(name: name, core: _core, configJson: raw);
      } else {
        await storage.update(
          item.copyWith(name: name, core: _core, configJson: raw),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.item != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit config' : 'New config'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
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
              selected: {_core},
              onSelectionChanged: (s) => _onCoreChanged(s.first),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _jsonController,
                minLines: null,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'Config JSON',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}