import 'package:flutter/material.dart';
import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/config_builders/core_config_builder.dart';
import 'package:any_core_vpn/vpn_service/rules/vpn_rules_service.dart';

class RuleEditorScreen extends StatefulWidget {
  final String presetName;
  final RoutingRule? existing;

  const RuleEditorScreen({required this.presetName, this.existing, super.key});

  @override
  State<RuleEditorScreen> createState() => _RuleEditorScreenState();
}

class _RuleEditorScreenState extends State<RuleEditorScreen> {
  late RoutingAction _action;
  late RuleDomainMatchType _domainType;
  late RoutingNetwork _network;
  late bool _enabled;

  late final TextEditingController _comment;
  late final TextEditingController _domains;
  late final TextEditingController _domainSets;
  late final TextEditingController _ipCidrs;
  late final TextEditingController _ipSets;
  late final TextEditingController _ports;
  late final TextEditingController _protocols;
  late final TextEditingController _apps;

  VpnCore get _core => MetaServiceConfigs.inst.selectedVpnCore.value;

  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    _action = r?.action ?? RoutingAction.proxy;
    _domainType = r?.domainType ?? RuleDomainMatchType.suffix;
    _network = r?.network ?? RoutingNetwork.both;
    _enabled = r?.enabled ?? true;
    _comment = TextEditingController(text: r?.comment ?? '');
    _domains = TextEditingController(text: r?.domains.join('\n') ?? '');
    _domainSets = TextEditingController(text: r?.domainSets.join('\n') ?? '');
    _ipCidrs = TextEditingController(text: r?.ipCidrs.join('\n') ?? '');
    _ipSets = TextEditingController(text: r?.ipSets.join('\n') ?? '');
    _ports = TextEditingController(text: r?.ports.join(', ') ?? '');
    _protocols = TextEditingController(text: r?.protocols.join('\n') ?? '');
    _apps = TextEditingController(text: r?.sourceApps.join('\n') ?? '');
  }

  @override
  void dispose() {
    _comment.dispose();
    _domains.dispose();
    _domainSets.dispose();
    _ipCidrs.dispose();
    _ipSets.dispose();
    _ports.dispose();
    _protocols.dispose();
    _apps.dispose();
    super.dispose();
  }

  List<String> _lines(TextEditingController c) => c.text
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  (List<int>?, String?) _parsePorts() {
    final chunks =
        _ports.text.split(RegExp(r'[\s,;]+')).where((c) => c.isNotEmpty);
    final out = <int>[];
    for (final c in chunks) {
      final port = int.tryParse(c);
      if (port == null || port < 1 || port > 65535) {
        return (null, 'Invalid port "$c" (expected 1..65535)');
      }
      out.add(port);
    }
    return (out, null);
  }

  /// Builds the rule currently described by the form, for live validation.
  RoutingRule _draft({List<int> ports = const []}) => RoutingRule(
        id: widget.existing?.id,
        action: _action,
        domainType: _domainType,
        domains: _lines(_domains),
        domainSets: _lines(_domainSets),
        ipCidrs: _lines(_ipCidrs),
        ipSets: _lines(_ipSets),
        ports: ports,
        protocols: _lines(_protocols).map((e) => e.toLowerCase()).toList(),
        sourceApps: _lines(_apps),
        network: _network,
        enabled: _enabled,
        comment: _comment.text.trim().isEmpty ? null : _comment.text.trim(),
      );

  Future<void> _save() async {
    final (ports, portError) = _parsePorts();
    if (portError != null) {
      _toast(portError);
      return;
    }

    final rule = _draft(ports: ports ?? const []);

    if (!rule.hasCriteria) {
      _toast('Add at least one criterion (domain, IP, port, protocol, app or transport)');
      return;
    }

    if (!rule.isUsableBy(_core)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('This rule does nothing on $_core'),
          content: Text(
            'Every criterion is unsupported by ${_core.name}: '
            '${rule.unsupportedCriteria(_core).join(', ')}.\n\n'
            'An empty rule would match EVERY connection, so it is dropped '
            'instead of being emitted. Save it anyway (it may work on the '
            'other core)?',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save anyway')),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      final existing = widget.existing;
      if (existing == null) {
        await VpnRulesService.instance
            .addRule(rule, presetName: widget.presetName);
      } else {
        await VpnRulesService.instance
            .updateRule(existing.id!, rule, presetName: widget.presetName);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _toast('$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  String _domainTypeLabel(RuleDomainMatchType t) => switch (t) {
        RuleDomainMatchType.suffix => 'Domain suffix (matches subdomains)',
        RuleDomainMatchType.keyword => 'Keyword (substring in host)',
        RuleDomainMatchType.exact => 'Exact domain',
        RuleDomainMatchType.regex => 'Regular expression',
      };

  Widget _section(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    String? helper,
    int maxLines = 3,
    bool unsupported = false,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: TextField(
          controller: controller,
          minLines: 1,
          maxLines: maxLines,
          textAlignVertical: TextAlignVertical.top,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: unsupported ? '$label (ignored by $_core)' : label,
            hintText: hint,
            helperText: helper,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
            enabledBorder: unsupported
                ? OutlineInputBorder(
                    borderSide: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant))
                : null,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final draft = _draft();
    final unsupportedXray = draft.unsupportedCriteria(VpnCore.xray);
    final unsupportedSingbox = draft.unsupportedCriteria(VpnCore.singbox);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null
            ? 'New rule · ${widget.presetName}'
            : 'Edit rule · ${widget.presetName}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (unsupportedXray.isNotEmpty || unsupportedSingbox.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 18, color: scheme.onTertiaryContainer),
                      const SizedBox(width: 8),
                      Text('Core compatibility',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.onTertiaryContainer)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (unsupportedXray.isNotEmpty)
                        'Xray ignores: ${unsupportedXray.join(', ')}',
                      if (unsupportedSingbox.isNotEmpty)
                        'sing-box ignores: ${unsupportedSingbox.join(', ')}',
                    ].join('\n'),
                    style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
                  ),
                ],
              ),
            ),
          _section('Action'),
          SegmentedButton<RoutingAction>(
            segments: const [
              ButtonSegment(
                  value: RoutingAction.proxy,
                  icon: Icon(Icons.vpn_lock),
                  label: Text('Proxy')),
              ButtonSegment(
                  value: RoutingAction.direct,
                  icon: Icon(Icons.public),
                  label: Text('Direct')),
              ButtonSegment(
                  value: RoutingAction.block,
                  icon: Icon(Icons.block),
                  label: Text('Block')),
            ],
            selected: {_action},
            onSelectionChanged: (s) => setState(() => _action = s.first),
          ),
          if (_action == RoutingAction.direct)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Direct = the destination sees your REAL IP.',
                style: TextStyle(fontSize: 12, color: scheme.tertiary),
              ),
            ),
          _section('State'),
          SwitchListTile(
            value: _enabled,
            title: const Text('Enabled'),
            subtitle: const Text(
                'Disabled rules are kept in the preset but skipped'),
            contentPadding: EdgeInsets.zero,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          _section('Transport'),
          SegmentedButton<RoutingNetwork>(
            segments: const [
              ButtonSegment(value: RoutingNetwork.both, label: Text('Any')),
              ButtonSegment(value: RoutingNetwork.tcp, label: Text('TCP')),
              ButtonSegment(value: RoutingNetwork.udp, label: Text('UDP')),
            ],
            selected: {_network},
            onSelectionChanged: (s) => setState(() => _network = s.first),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 8),
            child: Text(
              'Leave "Any" unless the rule is transport-specific (e.g. block '
              'QUIC = UDP + port 443).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          _field(
            _comment,
            'Comment (optional)',
            hint: 'Russian banks',
            helper: 'Shown in the rules list instead of the auto description.',
            maxLines: 1,
          ),
          _section('Domains'),
          DropdownButtonFormField<RuleDomainMatchType>(
            value: _domainType,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Domain match type',
              helperText: 'Applies to the "Domains" field below',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final t in RuleDomainMatchType.values)
                DropdownMenuItem(value: t, child: Text(_domainTypeLabel(t))),
            ],
            onChanged: (t) {
              if (t != null) setState(() => _domainType = t);
            },
          ),
          const SizedBox(height: 16),
          _field(
            _domains,
            'Domains (one per line)',
            hint: 'example.com\nyoutube.com',
          ),
          _field(
            _domainSets,
            'Geosite sets (one per line)',
            hint: 'google\nads',
            helper: 'Not usable today: Xray needs geosite.dat assets, sing-box '
                'removed geosite in 1.11+ (rule_set is the replacement).',
            unsupported: true,
          ),
          _section('IP'),
          _field(
            _ipCidrs,
            'IP / CIDR (one per line)',
            hint: '8.8.8.8/32\n77.88.0.0/16',
            helper: 'Needed for apps dialing hard-coded IPs (VK, Telegram, '
                'banks) - sniffing yields no domain there. Ranges covering the '
                'VPN server address are stripped automatically.',
            maxLines: 4,
          ),
          _field(
            _ipSets,
            'Geoip sets (one per line)',
            hint: 'ru\nde',
            helper: 'Not usable today (see geosite sets above).',
            unsupported: true,
          ),
          _section('Ports, protocols, apps'),
          _field(
            _ports,
            'Ports (comma separated)',
            hint: '443, 8080',
            helper: 'Combine with Transport = UDP to build a QUIC kill-switch.',
            maxLines: 1,
          ),
          _field(
            _protocols,
            'Protocols (one per line)',
            hint: 'dns\nquic\nstun\nbittorrent',
          ),
          _field(
            _apps,
            'Android apps / package names (one per line)',
            hint: 'org.telegram.messenger\ncom.android.chrome',
            helper: 'sing-box only. Xray needs a registered process finder '
                '(UID routing) and works in tunnel mode only.',
            unsupported: unsupportedXray.contains('apps'),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(widget.existing == null ? 'Add rule' : 'Save changes'),
            ),
          ),
        ],
      ),
    );
  }
}