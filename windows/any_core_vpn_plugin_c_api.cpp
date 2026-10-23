#include "include/any_core_vpn/any_core_vpn_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "any_core_vpn_plugin.h"

void AnyCoreVpnPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  any_core_vpn::AnyCoreVpnPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
