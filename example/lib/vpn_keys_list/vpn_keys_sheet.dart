import 'dart:async';

import 'package:flutter/material.dart';
import 'package:any_core_vpn/key_storage_service/vpn_key_storage_service.dart';
import 'package:any_core_vpn/vpn_service/link_parsers/link_parser.dart';

typedef OnKeySelected = void Function(VpnKeyData key);

Future<void> showVpnKeysSheet(
  BuildContext context, {
  required VpnKeyStorageService storage,
  required OnKeySelected onKeySelected,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _VpnKeysSheet(storage: storage, onKeySelected: onKeySelected),
    ),
  );
}

class _VpnKeysSheet extends StatefulWidget {
  final VpnKeyStorageService storage;
  final OnKeySelected onKeySelected;

  const _VpnKeysSheet({required this.storage, required this.onKeySelected});

  @override
  State<_VpnKeysSheet> createState() => _VpnKeysSheetState();
}

class _VpnKeysSheetState extends State<_VpnKeysSheet> {
  final _searchController = TextEditingController();

  StreamSubscription<List<VpnKeyData>>? _sub;
  ProtocolTypes? _protocolFilter;
  List<VpnKeyData> _keys = [];

  @override
  void initState() {
    super.initState();
    _keys = widget.storage.allKeys;
    _sub = widget.storage.keysStream.listen((keys) {
      if (mounted) setState(() => _keys = keys);
    });
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  List<VpnKeyData> get _filtered {
    final query = _searchController.text.trim().toLowerCase();
    return _keys.where((k) {
      if (_protocolFilter != null && k.protocol != _protocolFilter) {
        return false;
      }
      if (query.isNotEmpty && !k.name.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList();
  }

  Set<ProtocolTypes> get _availableProtocols =>
      _keys.map((k) => k.protocol).toSet();

  Future<void> _rename(VpnKeyData key) async {
    final controller = TextEditingController(text: key.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename key'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName != null && newName.isNotEmpty) {
      await widget.storage.renameKey(key.id, newName);
    }
  }

  Future<void> _remove(VpnKeyData key) async {
    await widget.storage.removeKey(key.id);
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove all keys?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove all'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.storage.clear();
  }

  @override
  Widget build(BuildContext context) {
    final keys = _filtered;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Saved keys (${_keys.length})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_keys.isNotEmpty)
                  IconButton(
                    tooltip: 'Remove all',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: _clearAll,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Filter by name…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => _searchController.clear(),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: const Text('All'),
                    selected: _protocolFilter == null,
                    onSelected: (_) => setState(() => _protocolFilter = null),
                  ),
                ),
                ..._availableProtocols.map(
                  (p) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(p.name),
                      selected: _protocolFilter == p,
                      onSelected: (_) =>
                          setState(() => _protocolFilter = p),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: keys.isEmpty
                ? const Center(child: Text('No keys'))
                : ListView.separated(
                    controller: scrollController,
                    itemCount: keys.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _KeyTile(
                      keyData: keys[i],
                      onConnect: () {
                        widget.onKeySelected(keys[i]);
                        Navigator.of(context).pop();
                      },
                      onRename: () => _rename(keys[i]),
                      onRemove: () => _remove(keys[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _KeyTile extends StatelessWidget {
  final VpnKeyData keyData;
  final VoidCallback onConnect;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  const _KeyTile({
    required this.keyData,
    required this.onConnect,
    required this.onRename,
    required this.onRemove,
  });

  String get _subtitle {
    if (keyData is VpnLinkKeyData) {
      final node = (keyData as VpnLinkKeyData).node;
      return '${node.protocol.name} · ${node.address}:${node.port}';
    }
    return '${keyData.keyType} · ${keyData.protocol.name}';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(child: Text(keyData.protocol.name[0].toUpperCase())),
      title: Text(keyData.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Connect',
            icon: const Icon(Icons.play_arrow),
            onPressed: onConnect,
          ),
          IconButton(
            tooltip: 'Rename',
            icon: const Icon(Icons.drive_file_rename_outline),
            onPressed: onRename,
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: onRemove,
          ),
        ],
      ),
      onTap: onConnect,
    );
  }
}