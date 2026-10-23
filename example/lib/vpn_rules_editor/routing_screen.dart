import 'dart:async';

import 'package:flutter/material.dart';
import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/config_builders/core_config_builder.dart';
import 'package:any_core_vpn/vpn_service/rules/vpn_rules_service.dart';

import 'rule_editor_screen.dart';

class RoutingScreen extends StatefulWidget {
  const RoutingScreen({super.key});

  @override
  State<RoutingScreen> createState() => _RoutingScreenState();
}

class _RoutingScreenState extends State<RoutingScreen> {
  StreamSubscription<VpnRulesChange>? _sub;

  VpnCore get _core => MetaServiceConfigs.inst.selectedVpnCore.value;

  @override
  void initState() {
    super.initState();
    _sub = VpnRulesService.instance.changes.listen((_) => _refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _createPreset() async {
    final name = await _promptText('New preset',
        hint: 'e.g. "work", "streaming"');
    if (name == null) return;
    try {
      await VpnRulesService.instance.createPreset(name: name);
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _copyPreset(VpnRulePreset preset) async {
    final name = await _promptText(
      'Copy "${preset.displayName}"',
      initial: '${preset.displayName} (copy)',
      hint: 'New preset name',
    );
    if (name == null) return;
    try {
      final copy =
          await VpnRulesService.instance.copyPreset(preset.name, name);
      _toast('Copied to "${copy.name}" - it is now editable');
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _renamePreset(VpnRulePreset preset) async {
    final name =
        await _promptText('Rename "${preset.displayName}"', initial: preset.name);
    if (name == null || name == preset.name) return;
    try {
      await VpnRulesService.instance.renamePreset(preset.name, name);
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _deletePreset(VpnRulePreset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${preset.displayName}"?'),
        content: Text('${preset.rules.length} rule(s) will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await VpnRulesService.instance.deletePreset(preset.name);
    if (!ok) _toast('Cannot delete "${preset.displayName}"');
  }

  Future<String?> _promptText(String title,
      {String? initial, String hint = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration:
              InputDecoration(hintText: hint, border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    return (result == null || result.isEmpty) ? null : result;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final service = VpnRulesService.instance;
    final activeName = service.activePresetName;
    final builtIns = service.presets.where((p) => p.builtIn).toList();
    final userPresets = service.presets.where((p) => !p.builtIn).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Routing rules')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createPreset,
        icon: const Icon(Icons.add),
        label: const Text('New preset'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          _InfoBanner(
            icon: Icons.alt_route,
            text: 'Rules are evaluated top-down inside a preset — first match '
                'wins. The active preset is applied on connect and on '
                'auto-reconnect.',
          ),
          const SizedBox(height: 8),
          _InfoBanner(
            icon: Icons.visibility_outlined,
            tone: _BannerTone.warn,
            text: '"Direct" means the destination sees your REAL IP. That is '
                'the point of a geo split (lower RTT, less tunnel volume), but '
                'leak-check and speedtest pages for that country will report '
                'your ISP address, not the VPN one.',
          ),
          const SizedBox(height: 16),
          _SectionHeader(title: 'My presets (${userPresets.length})'),
          for (final preset in userPresets)
            _PresetCard(
              preset: preset,
              active: preset.name == activeName,
              core: _core,
              onTap: () => _openPreset(preset),
              onActivate: () => service.activatePreset(preset.name),
              onCopy: () => _copyPreset(preset),
              onRename: preset.isDefault ? null : () => _renamePreset(preset),
              onDelete: preset.isDefault ? null : () => _deletePreset(preset),
            ),
          const SizedBox(height: 16),
          _SectionHeader(title: 'Built-in (${builtIns.length})'),
          Text(
            'Shipped with the app and refreshed on every launch. Copy one to '
            'edit it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          for (final preset in builtIns)
            _PresetCard(
              preset: preset,
              active: preset.name == activeName,
              core: _core,
              onTap: () => _openPreset(preset),
              onActivate: () => service.activatePreset(preset.name),
              onCopy: () => _copyPreset(preset),
            ),
        ],
      ),
    );
  }

  void _openPreset(VpnRulePreset preset) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PresetRulesScreen(presetName: preset.name),
    ));
  }
}

class PresetRulesScreen extends StatefulWidget {
  final String presetName;

  const PresetRulesScreen({required this.presetName, super.key});

  @override
  State<PresetRulesScreen> createState() => _PresetRulesScreenState();
}

class _PresetRulesScreenState extends State<PresetRulesScreen> {
  StreamSubscription<VpnRulesChange>? _sub;

  String get _presetName => widget.presetName;

  VpnCore get _core => MetaServiceConfigs.inst.selectedVpnCore.value;

  VpnRulePreset? get _preset =>
      VpnRulesService.instance.presetOrNull(_presetName);

  @override
  void initState() {
    super.initState();
    _sub = VpnRulesService.instance.changes.listen((change) {
      if (change.presetName == _presetName && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _openEditor([RoutingRule? rule]) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RuleEditorScreen(presetName: _presetName, existing: rule),
    ));
  }

  Future<void> _removeRule(RoutingRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove rule?'),
        content: Text(rule.comment ?? rule.describe(maxItems: 5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await VpnRulesService.instance
        .removeRule(rule.id!, presetName: _presetName);
    if (!ok) showSnackBar(context, 'Rule not found');
  }

  Future<void> _toggleEnabled(RoutingRule rule) async {
    await VpnRulesService.instance.setRuleEnabled(
      rule.id!,
      !rule.enabled,
      presetName: _presetName,
    );
  }

  void showSnackBar(BuildContext context, String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(s), behavior: SnackBarBehavior.floating));
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final preset = _preset;
    if (preset == null || preset.isReadOnly) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex < 0 || oldIndex >= preset.rules.length) return;
    final ruleId = preset.rules[oldIndex].id;
    if (ruleId == null) return;
    await VpnRulesService.instance
        .moveRule(ruleId, newIndex, presetName: _presetName);
  }

  Future<void> _copyPreset() async {
    final controller = TextEditingController(text: '${_presetName} (copy)');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Copy preset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'New name', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Copy')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    try {
      await VpnRulesService.instance.copyPreset(_presetName, name);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      showSnackBar(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final preset = _preset;
    final isActive = VpnRulesService.instance.activePresetName == _presetName;
    final readOnly = preset?.isReadOnly ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(preset?.displayName ?? _presetName,
            overflow: TextOverflow.ellipsis),
        actions: [
          if (readOnly)
            IconButton(
              tooltip: 'Copy preset to edit it',
              icon: const Icon(Icons.content_copy),
              onPressed: _copyPreset,
            ),
          if (isActive)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(child: _ActiveChip()),
            )
          else
            IconButton(
              tooltip: 'Set as active preset',
              icon: const Icon(Icons.check_circle_outline),
              onPressed: () =>
                  VpnRulesService.instance.activatePreset(_presetName),
            ),
        ],
      ),
      floatingActionButton: readOnly
          ? null
          : FloatingActionButton(
              onPressed: () => _openEditor(),
              child: const Icon(Icons.add),
            ),
      body: preset == null
          ? const Center(child: Text('This preset was deleted'))
          : Column(
              children: [
                if (preset.description != null || readOnly)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: Column(
                      children: [
                        if (readOnly)
                          _InfoBanner(
                            icon: Icons.lock_outline,
                            text: 'Built-in preset: read-only and refreshed on '
                                'every app launch. Use the copy button to '
                                'create an editable version.',
                          ),
                        if (preset.description != null) ...[
                          const SizedBox(height: 8),
                          _InfoBanner(
                            icon: Icons.info_outline,
                            text: preset.description!,
                          ),
                        ],
                      ],
                    ),
                  ),
                Expanded(
                  child: preset.rules.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.rule,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.outline),
                              const SizedBox(height: 8),
                              const Text('No rules — everything goes to the tunnel'),
                              const SizedBox(height: 4),
                              Text(
                                  readOnly
                                      ? 'This preset intentionally has no rules'
                                      : 'Tap + to add the first rule',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        )
                      : ReorderableListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
                          buildDefaultDragHandles: false,
                          itemCount: preset.rules.length,
                          onReorder: _reorder,
                          proxyDecorator: (child, index, animation) => Material(
                            elevation: 6,
                            borderRadius: BorderRadius.circular(12),
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            child: child,
                          ),
                          itemBuilder: (context, index) {
                            final rule = preset.rules[index];
                            return _RuleTile(
                              key: ValueKey(rule.id),
                              rule: rule,
                              index: index,
                              core: _core,
                              readOnly: readOnly,
                              canDrag: !readOnly,
                              onEdit: readOnly ? null : () => _openEditor(rule),
                              onRemove: readOnly ? null : () => _removeRule(rule),
                              onToggle:
                                  readOnly ? null : () => _toggleEnabled(rule),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _RuleTile extends StatelessWidget {
  final RoutingRule rule;
  final int index;
  final VpnCore core;
  final bool readOnly;
  final bool canDrag;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;
  final VoidCallback? onToggle;

  const _RuleTile({
    super.key,
    required this.rule,
    required this.index,
    required this.core,
    required this.readOnly,
    required this.canDrag,
    this.onEdit,
    this.onRemove,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (rule.action) {
      RoutingAction.proxy => (Icons.vpn_lock, Colors.indigo),
      RoutingAction.direct => (Icons.public, Colors.green),
      RoutingAction.block => (Icons.block, Colors.red),
    };

    final unsupported = rule.unsupportedCriteria(core);
    final usable = rule.isUsableBy(core);

    return Opacity(
      opacity: rule.enabled ? 1.0 : 0.45,
      child: ListTile(
        leading: canDrag
            ? ReorderableDragStartListener(
                index: index,
                child: CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.15),
                  foregroundColor: color,
                  child: Icon(icon, size: 20),
                ),
              )
            : CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.15),
                foregroundColor: color,
                child: Icon(icon, size: 20),
              ),
        title: Text(
          rule.comment ?? rule.describe(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '#${index + 1} · ${rule.action.name}'
              '${rule.domains.isNotEmpty ? ' · ${rule.domainType.name}' : ''}'
              '${rule.network != RoutingNetwork.both ? ' · ${rule.network.name}' : ''}'
              '${rule.enabled ? '' : ' · disabled'}',
              style: const TextStyle(fontSize: 11.5),
            ),
            if (!usable || unsupported.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  !usable
                      ? 'ignored by $core (no expressible criteria)'
                      : '$core ignores: ${unsupported.join(', ')}',
                  style: TextStyle(fontSize: 11, color: scheme.error),
                ),
              ),
            if (rule.comment != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(rule.describe(maxItems: 4),
                    style: TextStyle(fontSize: 11, color: scheme.outline)),
              ),
          ],
        ),
        isThreeLine: rule.comment != null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onToggle != null)
              Switch(value: rule.enabled, onChanged: (_) => onToggle!()),
            if (onRemove != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: onRemove,
              ),
          ],
        ),
        onTap: onEdit,
      ),
    );
  }
}

enum _BannerTone { info, warn }

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({
    required this.icon,
    required this.text,
    this.tone = _BannerTone.info,
  });

  final IconData icon;
  final String text;
  final _BannerTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = tone == _BannerTone.warn
        ? scheme.tertiaryContainer
        : scheme.surfaceContainerHighest;
    final foreground =
        tone == _BannerTone.warn ? scheme.onTertiaryContainer : scheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: foreground)),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4, left: 4),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _ActiveChip extends StatelessWidget {
  const _ActiveChip();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'active',
        style: TextStyle(fontSize: 11, color: scheme.onPrimaryContainer),
      ),
    );
  }
}

/// One preset row in [RoutingScreen].
///
/// Beyond name/active state it surfaces the two things that otherwise stay
/// invisible until a speedtest or a silent config rejection:
///  - how many rules the CURRENTLY SELECTED CORE can actually express
///    (`apps` on Xray, `geosite/geoip` on both, ...);
///  - how many rules are disabled.
class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.active,
    required this.core,
    required this.onTap,
    required this.onActivate,
    required this.onCopy,
    this.onRename,
    this.onDelete,
  });

  final VpnRulePreset preset;
  final bool active;
  final VpnCore core;

  /// Opens the rules list.
  final VoidCallback onTap;

  /// Makes this preset the active one.
  final VoidCallback onActivate;

  /// Forks it into an editable user preset.
  final VoidCallback onCopy;

  /// Null for built-in and default presets (both are non-renamable).
  final VoidCallback? onRename;

  /// Null for built-in and default presets (both are non-deletable).
  final VoidCallback? onDelete;

  /// Criteria kinds this core cannot express, aggregated over enabled rules.
  Set<String> _unsupportedCriteria() {
    final out = <String>{};
    for (final rule in preset.rules) {
      if (!rule.enabled) continue;
      out.addAll(rule.unsupportedCriteria(core));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final total = preset.rules.length;
    final disabled = preset.rules.where((r) => !r.enabled).length;
    final usable = preset.rules.where((r) => r.isUsableBy(core)).length;
    final ignored = total - usable;
    final unsupported = _unsupportedCriteria();

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: active ? scheme.primaryContainer : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _leadingIcon,
                    color: active ? scheme.primary : scheme.outline,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      preset.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (preset.builtIn)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _MiniBadge(
                        label: 'built-in',
                        background: scheme.surfaceContainerHighest,
                        foreground: scheme.onSurfaceVariant,
                        tooltip: 'Shipped with the app, refreshed on every '
                            'launch. Copy it to edit.',
                      ),
                    ),
                  if (active) const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: _ActiveChip(),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Preset actions',
                    onSelected: (value) {
                      switch (value) {
                        case 'activate':
                          onActivate();
                        case 'copy':
                          onCopy();
                        case 'rename':
                          onRename?.call();
                        case 'delete':
                          onDelete?.call();
                      }
                    },
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      if (!active)
                        const PopupMenuItem<String>(
                          value: 'activate',
                          child: Text('Set active'),
                        ),
                      const PopupMenuItem<String>(
                        value: 'copy',
                        child: Text('Copy…'),
                      ),
                      if (onRename != null)
                        const PopupMenuItem<String>(
                          value: 'rename',
                          child: Text('Rename'),
                        ),
                      if (onDelete != null)
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                    ],
                  ),
                ],
              ),

              // ---- stats ----
              Padding(
                padding: const EdgeInsets.only(left: 36, top: 4),
                child: Text(
                  _statsLine(total, usable, disabled),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),

              // ---- ignored criteria warning ----
              if (ignored > 0 || unsupported.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 36, top: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline,
                          size: 14, color: scheme.tertiary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          ignored > 0
                              ? '$ignored rule(s) ignored by ${core.name}'
                                  '${unsupported.isEmpty ? '' : ': ${unsupported.join(', ')}'}'
                              : '$core ignores: ${unsupported.join(', ')}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.tertiary),
                        ),
                      ),
                    ],
                  ),
                ),

              // ---- description ----
              if (preset.description != null &&
                  preset.description!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 36, right: 12, top: 6),
                  child: Text(
                    preset.description!.trim(),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),

              // ---- read-only hint ----
              if (preset.isReadOnly)
                Padding(
                  padding: const EdgeInsets.only(left: 36, top: 6),
                  child: Row(
                    children: [
                      Icon(Icons.lock_outline, size: 14, color: scheme.outline),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Read-only · tap the menu to copy and edit',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.outline),
                        ),
                      ),
                    ],
                  ),
                ),

              // ---- quick activate when not active ----
              if (!active)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onActivate,
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text('Set active'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData get _leadingIcon {
    if (preset.builtIn) {
      return switch (preset.name) {
        'geo-ru-direct' || 'geo-ru-proxy' => Icons.location_on_outlined,
        'geo-tr-direct' => Icons.location_on_outlined,
        'geo-gb-direct' => Icons.location_on_outlined,
        _ => Icons.public,
      };
    }
    return preset.isDefault ? Icons.home_work_outlined : Icons.tune;
  }

  String _statsLine(int total, int usable, int disabled) {
    if (total == 0) return 'no rules · everything goes through the tunnel';
    final parts = <String>[
      '$total rule(s)',
      '$usable for $core',
      if (disabled > 0) '$disabled disabled',
    ];
    return parts.join(' · ');
  }
}

/// Small pill used for the "built-in" marker.
class _MiniBadge extends StatelessWidget {
  const _MiniBadge({
    required this.label,
    required this.background,
    required this.foreground,
    this.tooltip,
  });

  final String label;
  final Color background;
  final Color foreground;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: foreground),
      ),
    );

    if (tooltip == null) return chip;
    return Tooltip(message: tooltip!, child: chip);
  }
}