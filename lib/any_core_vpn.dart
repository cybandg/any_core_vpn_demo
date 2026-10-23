import 'package:any_core_vpn/vpn_service/realisations/android/android_vpn_service.dart';
import 'package:any_core_vpn/vpn_service/realisations/ios/ios_vpn_service.dart';
import 'package:any_core_vpn/vpn_service/realisations/macos/macos_vpn_service.dart';
import 'package:any_core_vpn/vpn_service/realisations/windows/windows_vpn_service.dart';
import 'package:any_core_vpn/vpn_service/vpn_service.dart';

enum SupportedPlatforms{
  android,
  ios,
  macos,
  windows,
}

class AnyCoreVpn {
  ///alternative of createAndInitVpnService but without initialisation.
  ///You should call vpnService.init() by yourself though befor start using it's methods.
  VpnService createVpnService(SupportedPlatforms? platform){
    SupportedPlatforms platformToCreate = platform??SupportedPlatforms.android;

    switch(platformToCreate){
      case SupportedPlatforms.android:
        return AndroidVpnService();
      case SupportedPlatforms.ios:
        return IOSVpnService();
      case SupportedPlatforms.macos:
        return MacOSVpnService();
      case SupportedPlatforms.windows:
        return WindowsVpnService();
    }
  }

  ///Authomatically creates and initializes VpnService instance. So you can use it's methods in the next line after await anyCoreVpn.createAndInitVpnService();
  Future<VpnService> createAndInitVpnService(SupportedPlatforms? platform) async {
    var service = createVpnService(platform);
    await service.init();

    return service;
  }
}
