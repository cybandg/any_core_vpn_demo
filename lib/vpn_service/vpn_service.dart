import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/configs/core_versions.dart';
import 'package:any_core_vpn/vpn_service/rules/vpn_rules_service.dart';

abstract class VpnService {
  VpnService();

  Future<void> init() async {
    await MetaServiceConfigs.inst.initMetaConfigs();
    await VpnRulesService.instance.init();
  }

  Future<bool> connect(String link);

  Future<void> disconnect();

  Future<bool> isRunning();

  Stream<String> get logStream => const Stream<String>.empty();

  /// Versions of the bundled cores, for feature gating.
  Future<CoreVersions> coreVersions() async => const CoreVersions();

  Future<bool> connectViaConfig(Map<String, dynamic> config) {
    throw UnimplementedError(
      'connectViaConfig is not supported on $runtimeType',
    );
  }

  /// Absolute paths of the on-disk core config dumps, keyed by core.
  Future<Map<VpnCore, String>> coreConfigPaths() async => const {};
}
