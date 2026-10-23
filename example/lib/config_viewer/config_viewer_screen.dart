import 'dart:convert';
import 'dart:io';

import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/vpn_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Read-only viewer for the core config dumps the plugin already writes to
/// disk (`cache/xray_config.json`, `cache/singbox_config.json` on Android,
/// `<session>/config.json` on macOS).
///
/// It shows the config AFTER native patching (tun fd, mtu, log paths), i.e.
/// exactly what the core was handed - which is what you want when a config is
/// rejected.
///
/// Deliberately knows NOTHING about which core is currently connected: it just
/// lets you jump between the two dumps.
class ConfigViewerScreen extends StatefulWidget {
  const ConfigViewerScreen({required this.service, super.key});

  final VpnService service;

  @override
  State<ConfigViewerScreen> createState() => _ConfigViewerScreenState();
}

class _ConfigViewerScreenState extends State<ConfigViewerScreen> {
  /// Lists longer than this start collapsed: the geo presets carry 100+
  /// domain entries and would otherwise bury the structure.
  static const int _autoCollapseThreshold = 25;

  late VpnCore _core = MetaServiceConfigs.inst.selectedVpnCore.value;

  Map<VpnCore, String> _paths = const {};
  String? _path;
  String? _raw;
  dynamic _json;
  String? _error;
  int? _size;
  DateTime? _mtime;
  bool _loading = false;
  bool _treeView = true;

  /// Node paths the user collapsed (plus auto-collapsed long lists).
  Set<String> _collapsed = {};

  String? _versionLine;

  Future<void> _loadVersions() async {
    try {
      final versions = await widget.service.coreVersions();
      if (!mounted) return;
      setState(() => _versionLine = 'cores: ${versions.describe()}');
    } catch (_) {
      // Versions are informational; never block the viewer.
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadVersions();
  }

  String? get _prettyRaw {
    final decoded = _json;
    if (decoded == null) return _raw;
    return const JsonEncoder.withIndent('  ').convert(decoded);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _raw = null;
      _json = null;
      _path = null;
      _size = null;
      _mtime = null;
      _collapsed = {};
    });

    try {
      final paths = await widget.service.coreConfigPaths();
      if (!mounted) return;

      setState(() => _paths = paths);

      final path = paths[_core];
      if (path == null) {
        setState(() {
          _loading = false;
          _error = 'This platform does not dump ${_core.name} configs.';
        });
        return;
      }

      final file = File(path);
      if (!await file.exists()) {
        setState(() {
          _loading = false;
          _path = path;
          _error =
              'File not found:\n$path\n\n'
              'Connect with ${_core.name} at least once - the dump is written '
              'when the core starts.';
        });
        return;
      }

      final stat = await file.stat();
      final raw = await file.readAsString();

      dynamic decoded;
      Object? decodeError;
      try {
        decoded = jsonDecode(raw);
      } catch (e) {
        decodeError = e;
      }

      if (!mounted) return;
      setState(() {
        _loading = false;
        _path = path;
        _raw = raw;
        _json = decoded;
        _size = stat.size;
        _mtime = stat.modified;
        _collapsed = _autoCollapse(decoded);
        // Not fatal: an undecodable dump is still worth reading as text.
        _error = decoded == null ? 'Not valid JSON: $decodeError' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// Collapses long arrays by default so the outline stays readable.
  Set<String> _autoCollapse(dynamic value, {String path = ''}) {
    final out = <String>{};

    void walk(dynamic node, String nodePath) {
      if (node is Map) {
        node.forEach(
          (key, child) => walk(child, '$nodePath/${key.toString()}'),
        );
      } else if (node is List) {
        if (node.length > _autoCollapseThreshold) out.add(nodePath);
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$nodePath[$i]');
        }
      }
    }

    walk(value, path);
    return out;
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Copied $what (${text.length} chars)'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _toggle(String path) {
    setState(() {
      if (_collapsed.contains(path)) {
        _collapsed.remove(path);
      } else {
        _collapsed.add(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasContent = _raw != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Core config'),
        actions: [
          IconButton(
            tooltip: _treeView ? 'Raw text' : 'Tree view',
            onPressed: hasContent
                ? () => setState(() => _treeView = !_treeView)
                : null,
            icon: Icon(
              _treeView ? Icons.data_object : Icons.account_tree_outlined,
            ),
          ),
          IconButton(
            tooltip: 'Reload from disk',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(scheme),
            Expanded(child: _buildBody(scheme)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _copy(_prettyRaw ?? _raw ?? '', 'whole config'),
        child: const Icon(Icons.copy_all, size: 18),
      ),
      //bottomNavigationBar: hasContent ? _buildBottomBar(scheme) : null,
    );
  }

  Widget _buildHeader(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<VpnCore>(
            segments: [
              for (final core in VpnCore.values)
                ButtonSegment(
                  value: core,
                  label: Text(core.name),
                  icon: const Icon(Icons.description_outlined),
                ),
            ],
            selected: {_core},
            onSelectionChanged: (selection) {
              setState(() => _core = selection.first);
              _load();
            },
          ),
          const SizedBox(height: 8),
          if (_versionLine != null)
            Text(
              _versionLine!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          if (_path != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _path!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: scheme.outline,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy path',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.link, size: 18),
                  onPressed: () => _copy(_path!, 'path'),
                ),
              ],
            ),
          if (_size != null)
            Text(
              '${(_size! / 1024).toStringAsFixed(1)} KB · '
              'modified ${_mtime?.toLocal().toString().split('.').first ?? '—'}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    final error = _error;
    final raw = _raw;

    if (error != null && raw == null) {
      return _buildMessage(scheme, error);
    }

    if (raw == null) {
      return _buildMessage(scheme, 'Nothing loaded yet.');
    }

    if (_treeView && _json != null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 64),
        child: _JsonNode(
          value: _json,
          path: '',
          depth: 0,
          collapsed: _collapsed,
          onToggle: _toggle,
          onCopy: _copy,
          rootLabel: _core.name,
        ),
      );
    }

    // Raw / undecodable fallback.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error,
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
          SelectableText(
            _prettyRaw ?? raw,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(ColorScheme scheme, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 44, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Reload'),
            ),
          ],
        ),
      ),
    );
  }

  /*

  Widget _buildBottomBar(ColorScheme scheme) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: () =>
                    _copy(_prettyRaw ?? _raw ?? '', 'whole config'),
                icon: const Icon(Icons.copy_all, size: 18),
                label: const Text('Copy all'),
              ),
            ),
          ],
        ),
      ),
    );
  }*/
}

/// Recursive JSON tree node.
///
/// Every container (map/list) carries its own copy button: it copies that
/// subtree as pretty JSON, which is what you actually want to paste into an
/// issue or diff against the provider config.
class _JsonNode extends StatelessWidget {
  const _JsonNode({
    required this.value,
    required this.path,
    required this.depth,
    required this.collapsed,
    required this.onToggle,
    required this.onCopy,
    this.keyName,
    this.index,
    this.rootLabel,
  });

  final dynamic value;
  final String path;
  final int depth;
  final Set<String> collapsed;
  final void Function(String path) onToggle;
  final void Function(String text, String what) onCopy;

  /// Map key or list index that led here.
  final String? keyName;
  final int? index;

  /// Only set on the root node.
  final String? rootLabel;

  bool get _isContainer => value is Map || value is List;

  bool get _expanded => !collapsed.contains(path);

  int get _childCount => value is Map
      ? (value as Map).length
      : value is List
      ? (value as List).length
      : 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final indent = 14.0 * depth;

    if (!_isContainer) {
      return Padding(
        padding: EdgeInsets.only(left: indent + 22, top: 1, bottom: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (keyName != null) ...[
              Flexible(
                child: Text(
                  '$keyName: ',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: scheme.primary,
                  ),
                ),
              ),
            ] else if (index != null)
              Text(
                '$index: ',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: scheme.outline,
                ),
              ),
            Expanded(
              child: SelectableText(
                _scalarText(value),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: _scalarColor(scheme, value),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final label =
        keyName ?? (index != null ? '[$index]' : (rootLabel ?? 'root'));
    final bracket = value is Map ? ('{', '}') : ('[', ']');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => onToggle(path),
          child: Padding(
            padding: EdgeInsets.only(left: indent, top: 2, bottom: 2),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 18,
                  color: scheme.outline,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${bracket.$1} $_childCount ${bracket.$2}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Copy this fragment',
                  visualDensity: VisualDensity.compact,
                  iconSize: 15,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  icon: const Icon(Icons.copy_all_outlined),
                  onPressed: () => onCopy(
                    const JsonEncoder.withIndent('  ').convert(value),
                    '"$label" fragment',
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          if (value is Map)
            for (final entry in (value as Map).entries)
              _JsonNode(
                value: entry.value,
                path: '$path/${entry.key.toString()}',
                depth: depth + 1,
                collapsed: collapsed,
                onToggle: onToggle,
                onCopy: onCopy,
                keyName: entry.key.toString(),
              )
          else
            for (var i = 0; i < (value as List).length; i++)
              _JsonNode(
                value: value[i],
                path: '$path[$i]',
                depth: depth + 1,
                collapsed: collapsed,
                onToggle: onToggle,
                onCopy: onCopy,
                index: i,
              )
        else
          Padding(
            padding: EdgeInsets.only(left: indent + 22),
            child: Text(
              _previewCollapsed(value),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: scheme.outline,
              ),
            ),
          ),
      ],
    );
  }

  String _scalarText(dynamic v) {
    if (v == null) return 'null';
    if (v is String) return '"$v"';
    return v.toString();
  }

  Color _scalarColor(ColorScheme scheme, dynamic v) {
    if (v == null) return scheme.outline;
    if (v is bool) return Colors.deepPurple;
    if (v is num) return Colors.orange.shade800;
    return Colors.teal.shade700;
  }

  /// One-line hint of what is hidden, so a collapsed long list is still
  /// identifiable without expanding it.
  String _previewCollapsed(dynamic v) {
    if (v is Map) {
      final keys = v.keys.take(4).map((e) => e.toString()).join(', ');
      return '{ $keys${v.length > 4 ? ', …' : ''} }';
    }
    if (v is List) {
      final first = v
          .take(3)
          .map((e) => e is String ? '"$e"' : '$e')
          .join(', ');
      return '[ $first${v.length > 3 ? ', … +${v.length - 3}' : ''} ]';
    }
    return '';
  }
}
