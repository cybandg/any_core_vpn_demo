import 'package:any_core_vpn/vpn_service/exceptions/vpn_service_exception.dart';
import 'package:any_core_vpn/vpn_service/vpn_service.dart';

class WindowsVpnService extends VpnService {
  @override
  Future<bool> connect(String link) {
    throw UnsupportedInDemoVersionException(featureDescriprion: "WINDOWS platform integration");
  }

  @override
  Future<void> disconnect() {
    throw UnsupportedInDemoVersionException(featureDescriprion: "WINDOWS platform integration");
  }

  @override
  Future<bool> isRunning() {
    throw UnsupportedInDemoVersionException(featureDescriprion: "WINDOWS platform integration");
  }
}
