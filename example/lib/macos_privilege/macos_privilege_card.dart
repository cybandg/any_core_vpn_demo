import 'dart:io';

import 'package:any_core_vpn/vpn_service/realisations/macos/macos_cores.dart';
import 'package:any_core_vpn/vpn_service/realisations/macos/macos_privileged_launcher.dart';
import 'package:flutter/material.dart';

/// One-time installer UI for the password-free supervisor launch (macOS only).
class MacosPasswordlessCard extends StatefulWidget {
  const MacosPasswordlessCard({super.key});

  @override
  State<MacosPasswordlessCard> createState() => _MacosPasswordlessCardState();
}

class _MacosPasswordlessCardState extends State<MacosPasswordlessCard> {
  final _launcher = MacosPrivilegedLauncher.instance;

  PasswordlessStatus? _status;
  String? _detail;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isMacOS) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final files = await const MacosCoresLocator().locate();
      final status = await _launcher.status(files);
      if (!mounted) return;
      setState(() {
        _status = status;
        _detail = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = null;
        _detail = '$error';
      });
    }
  }

  Future<void> _run(Future<void> Function(MacosCoreFiles files) action) async {
    setState(() => _busy = true);
    try {
      final files = await const MacosCoresLocator().locate();
      await action(files);
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Done')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall() async {
    setState(() => _busy = true);
    try {
      await _launcher.uninstall();
      await _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) return const SizedBox.shrink();

    final status = _status;
    final (String title, String subtitle, IconData icon, Color color) =
        switch (status) {
      PasswordlessStatus.ready => (
          'Password-free start: ON',
          'sudo -n ${MacosPrivilegedLauncher.wrapper} · no dialog on connect',
          Icons.verified_user,
          Colors.green,
        ),
      PasswordlessStatus.outdated => (
          'Password-free start: outdated',
          'Pinned cores differ from the bundle — reinstall to update them',
          Icons.system_update,
          Colors.orange,
        ),
      PasswordlessStatus.broken => (
          'Password-free start: broken',
          'Files present but sudo -n refuses — reinstall',
          Icons.error_outline,
          Colors.red,
        ),
      PasswordlessStatus.notInstalled => (
          'Password-free start: OFF',
          'One admin prompt to install, then connects never ask for a password',
          Icons.lock_outline,
          Theme.of(context).colorScheme.outline,
        ),
      null => (
          'Password-free start: unknown',
          _detail ?? 'Checking…',
          Icons.help_outline,
          Theme.of(context).colorScheme.outline,
        ),
    };

    final canInstall = status == PasswordlessStatus.notInstalled ||
        status == PasswordlessStatus.outdated ||
        status == PasswordlessStatus.broken;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title),
        subtitle: Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Wrap(
                spacing: 4,
                children: [
                  if (canInstall)
                    TextButton(
                      onPressed: () => _run(_launcher.install),
                      child: const Text('Install'),
                    ),
                  if (status == PasswordlessStatus.ready)
                    TextButton(
                      onPressed: _uninstall,
                      child: const Text('Remove'),
                    ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                ],
              ),
      ),
    );
  }
}