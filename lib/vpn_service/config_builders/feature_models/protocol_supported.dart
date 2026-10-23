part of '../core_config_builder.dart';

enum SupportedPlatforms{
  android,
  ios,
  macos,
  windows,
}

enum ProtocolSupportStatus{
  supported,
  unsupported,
  yetUnsupported,
  supportedInPaidVersion,
}

class ProtocolSupportedChecker{
   static ProtocolSupportStatus isProtocolSupported(ProtocolTypes protocol, SupportedPlatforms platform, VpnCore sellectedVpnCore){
      switch(platform){
        case SupportedPlatforms.android:
          return androidProtocolSupportion[sellectedVpnCore]![protocol]??ProtocolSupportStatus.unsupported;
        case SupportedPlatforms.ios:
          return ProtocolSupportStatus.yetUnsupported;
        case SupportedPlatforms.macos:
          return macosProtocolSupportion[sellectedVpnCore]![protocol]??ProtocolSupportStatus.unsupported;
        case SupportedPlatforms.windows:
          return ProtocolSupportStatus.supportedInPaidVersion;
      }
   }
}

const Map<VpnCore, Map<ProtocolTypes, ProtocolSupportStatus>> androidProtocolSupportion = {
  VpnCore.xray : {
    ProtocolTypes.vless: ProtocolSupportStatus.supported,
    ProtocolTypes.vmess: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.shadowsocks: ProtocolSupportStatus.supported,
    ProtocolTypes.trojan: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.wireguard: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.hysteria2: ProtocolSupportStatus.unsupported,
    ProtocolTypes.tuic: ProtocolSupportStatus.unsupported,
    ProtocolTypes.ssh: ProtocolSupportStatus.unsupported,
    ProtocolTypes.notSupported: ProtocolSupportStatus.unsupported,
  },
  VpnCore.singbox : {
    ProtocolTypes.vless: ProtocolSupportStatus.supported,
    ProtocolTypes.vmess: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.shadowsocks: ProtocolSupportStatus.supported,
    ProtocolTypes.trojan: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.wireguard: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.hysteria2: ProtocolSupportStatus.supported,
    ProtocolTypes.tuic: ProtocolSupportStatus.supported,
    ProtocolTypes.ssh: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.notSupported: ProtocolSupportStatus.unsupported,
  },
};


const Map<VpnCore, Map<ProtocolTypes, ProtocolSupportStatus>> macosProtocolSupportion = {
  VpnCore.xray : {
    ProtocolTypes.vless: ProtocolSupportStatus.supported,
    ProtocolTypes.vmess: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.shadowsocks: ProtocolSupportStatus.supported,
    ProtocolTypes.trojan: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.wireguard: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.hysteria2: ProtocolSupportStatus.unsupported,
    ProtocolTypes.tuic: ProtocolSupportStatus.unsupported,
    ProtocolTypes.ssh: ProtocolSupportStatus.unsupported,
    ProtocolTypes.notSupported: ProtocolSupportStatus.unsupported,
  },
  VpnCore.singbox : {
    ProtocolTypes.vless: ProtocolSupportStatus.supported,
    ProtocolTypes.vmess: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.shadowsocks: ProtocolSupportStatus.supported,
    ProtocolTypes.trojan: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.wireguard: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.hysteria2: ProtocolSupportStatus.supported,
    ProtocolTypes.tuic: ProtocolSupportStatus.supported,
    ProtocolTypes.ssh: ProtocolSupportStatus.supportedInPaidVersion,
    ProtocolTypes.notSupported: ProtocolSupportStatus.unsupported,
  },
};