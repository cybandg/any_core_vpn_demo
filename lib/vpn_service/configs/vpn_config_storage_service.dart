library;

import 'package:any_core_vpn/vpn_service/configs/core_versions.dart';

enum VpnConfigChangeType { added, updated, removed }

class VpnConfigChange {
  const VpnConfigChange({required this.type, required this.configId});

  final VpnConfigChangeType type;
  final String configId;

  @override
  String toString() => 'VpnConfigChange(${type.name}, $configId)';
}

class VpnConfigStorageService {
  VpnConfigStorageService._();

  static final VpnConfigStorageService instance = VpnConfigStorageService._();

  CoreVersions _versions = const CoreVersions();

  /// Refreshed by the platform service; used for feature gating in reports.
  CoreVersions get versions => _versions;

  void setVersions(CoreVersions versions) {
    _versions = versions;
  }
}
