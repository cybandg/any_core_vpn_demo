# any_core_vpn — Flutter VPN plugin for sing-box and Xray

**One Dart API for sing-box (singbox) and Xray-core. Build Flutter VPN clients for Android and Apple Silicon macOS with the public freemium edition. Windows integration is available separately in the commercial edition.**

`any_core_vpn` simplifies VPN client development by providing a shared connection interface for two networking cores. Connect using supported share links or core-specific JSON configurations, store connection keys, and manage routing presets without maintaining separate application-level connection APIs for sing-box and Xray.

This package is the **public demo / freemium edition**.

[Русский README](README.ru.md) ·
[IMPORTANT before startup (Instalation)](#installation) ·
[Documentation](docs/README.md) ·
[Full edition](#windows-vpn-support-and-the-full-edition) ·
[License](DEMO_LICENSE.md) ·
[Telegram updates](https://t.me/any_core_vpn) ·
[Contact](#contact-and-custom-vpn-development)

## Features

| Feature | What you get |
| --- | --- |
| Unified Dart API | Initialize, connect, disconnect, and check running state through `VpnService`. |
| Two networking cores | Use sing-box or Xray through the same basic connection interface. |
| Share-link connections | Connect with protocols included in the freemium edition. |
| Existing JSON configurations | Connect with a compatible configuration through `connectViaConfig()`, within the edition's permitted capabilities. |
| Core setup tools | Build Android core libraries and prepare macOS core binaries. |
| Configurable core versions | Set versions in `setup_cores.json` or use setup CLI overrides. |
| Configuration builders | Customize supported TUN, DNS, routing, inbound, and outbound settings. |
| Secure key storage | Save connection keys using `VpnKeyStorageService` and `flutter_secure_storage`. |
| Routing presets | Create and manage proxy, direct, and block rules. |
| Sniffing | Use supported connection metadata inspection to assist routing. |
| Diagnostics | Read runtime logs and available platform-specific diagnostic information. |

**Unified API does not mean identical capabilities.** Protocols, configuration fields, permissions, and connection modes depend on the core, platform, and edition.

## Platform availability

| Platform | Public freemium package | Full commercial edition | Connection modes and notes |
| --- | --- | --- | --- |
| Android | ✅ Publicly available | ✅ Available | sing-box and Xray: TUN and HEV-backed `systemProxy`. Both modes require Android VPN permission. |
| macOS — Apple Silicon ARM64 | ✅ Publicly available | ✅ Available | sing-box and Xray: system proxy and TUN. Native ARM64 only, without Rosetta. |
| Windows | 🔒 Not included — [contact for access](https://t.me/ElfimovAI) | ✅ Available separately | sing-box: system proxy and TUN. Xray: system proxy only. |
| iOS | 🚧 Not available yet | 🚧 Priority development | VPN operations are not implemented yet. |
| Linux / Web | ❌ No backend provided | ❌ No backend provided | Not currently supported. |

### Connection modes

- **TUN** is a virtual network interface used to route IP traffic.
- **System proxy on desktop** is used by applications that honor the relevant operating-system proxy settings. It does not automatically cover every application.
- **HEV on Android** is a tun2socks bridge that forwards traffic from the VPN interface to a SOCKS listener. Android `systemProxy` is not merely a global proxy setting.

Dart mode values are `ConnectionMode.systemProxy` and `ConnectionMode.tunnel`.

The current macOS integration uses `osascript` for administrator operations, with an optional installed sudo-wrapper launch path.

## Protocol availability

The public edition includes **VLESS, Shadowsocks, Hysteria2, and TUIC**, subject to the selected core's capabilities.

| Protocol | sing-box in freemium | Xray-core in freemium | Full edition |
| --- | --- | --- | --- |
| VLESS | ✅ Available | ✅ Available | ✅ Available |
| Shadowsocks | ✅ Available | ✅ Available | ✅ Available |
| Hysteria2 | ✅ Available | ❌ Not supported by the core | ✅ Available with sing-box |
| TUIC | ✅ Available | ❌ Not supported by the core | ✅ Available with sing-box |
| VMess | 🔒 Full edition only | 🔒 Full edition only | Declared supported — [contact me](https://t.me/ElfimovAI) |
| Trojan | 🔒 Full edition only | 🔒 Full edition only | Declared supported — [contact me](https://t.me/ElfimovAI) |
| WireGuard | 🔒 Full edition only | 🔒 Full edition only | Declared supported, with integration limitations — [contact me](https://t.me/ElfimovAI) |
| SSH | 🔒 Full edition only | ❌ Not supported by the core | Declared supported with sing-box — [contact me](https://t.me/ElfimovAI) |

**A full-edition license does not add protocols unsupported by a core.** Use sing-box for Hysteria2, TUIC, and SSH.

Protocol availability does not guarantee support for every transport, share-link variation, authentication method, or configuration option.

Important integration limitations:

- Desktop share-link runners reject external Shadowsocks plugins.
- The current full-edition Windows/macOS sing-box WireGuard share-link path rejects legacy generated configurations. Declared core support is not a claim that this path works.
- Custom JSON is not an unrestricted entitlement to features excluded from freemium.

See [protocols and share links](docs/protocols.md).

## Default core targets

| Core | Setup setting | Default target |
| --- | --- | --- |
| Xray-core | `xrayVersion` | `26.7.28` |
| sing-box | `singboxVersion` | `1.14.2` |

These are project compatibility targets, not a claim that they are the latest stable upstream releases.

Change versions in:

```text
<plugin_root>/setup_cores.json
```

Setup CLI arguments can override configured versions. Core changes may require configuration or native integration changes.

## Installation

### 1. Add the public Flutter package

Run from your Flutter application:

```bash
flutter pub add any_core_vpn
flutter pub get
```

### 2. Prepare the native cores

**Adding the Dart dependency is not enough.**

#### Android

Build and install `libbox.aar` and `libXray.aar`:

```bash
flutter pub run any_core_vpn:setup_android_cores
```

#### macOS

Prepare ARM64 sing-box and Xray binaries and compile the Swift helper:

```bash
flutter pub run any_core_vpn:setup_macos_cores
```

P.S. If you plan to modify this version of plugin make sure, that root of the plugin is named 'any_core_vpn' (not 'any_core_vpn_demo') 
to avoid some limitation while building your apps. 

#### Available commands

```bash
flutter pub run any_core_vpn:help
```

The equivalent executable syntax is:

```bash
dart run any_core_vpn:help
```

**Windows setup is not part of this public edition.** Commercial access includes the applicable Windows installation instructions.

### 3. Check environment and permissions

- Android core builds require Git, Python, a compatible Go toolchain, JDK, Android SDK, and NDK.
- macOS setup requires native Apple Silicon, Xcode command-line tools, `tar`, and `ditto`.
- Handle Android VPN permission denial and macOS administrator approval.
- Rebuild the application after changing packaged core artifacts.
- Test the actual routing and DNS behavior on your target devices.

See [installation](docs/installation.md).

## Quick start: connect with a share link

This complete example library initializes the appropriate public-platform service and connects using sing-box in system proxy mode:

```dart
import 'dart:io';

import 'package:any_core_vpn/any_core_vpn.dart' as vpn_factory;
import 'package:any_core_vpn/meta_service_configs/meta_service_configs.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/connection_mode_config.dart';
import 'package:any_core_vpn/meta_service_configs/specific_configs/selected_vpn_core_config.dart';
import 'package:any_core_vpn/vpn_service/vpn_service.dart';
import 'package:flutter/widgets.dart';

Future<VpnService> connectFreemiumVpn(String shareLink) async {
  WidgetsFlutterBinding.ensureInitialized();

  final link = shareLink.trim();
  if (link.isEmpty) {
    throw ArgumentError('The connection link must not be empty.');
  }

  final vpn_factory.SupportedPlatforms platform;

  if (Platform.isAndroid) {
    platform = vpn_factory.SupportedPlatforms.android;
  } else if (Platform.isMacOS) {
    platform = vpn_factory.SupportedPlatforms.macos;
  } else {
    throw UnsupportedError(
      'This freemium example supports Android and macOS only.',
    );
  }

  final service =
      await vpn_factory.AnyCoreVpn().createAndInitVpnService(platform);

  MetaServiceConfigs.inst.selectedVpnCore.updateValue(VpnCore.singbox);
  MetaServiceConfigs.inst.sellectedConnectionMode.updateValue(
    ConnectionMode.systemProxy,
  );

  final connected = await service.connect(link);

  if (!connected) {
    throw StateError('The VPN service did not reach its running state.');
  }

  return service;
}
```

Pass a valid VLESS, Shadowsocks, Hysteria2, or TUIC link compatible with the selected core.

To use Xray, select `VpnCore.xray` and a protocol supported by Xray in this edition. To use TUN, select `ConnectionMode.tunnel`.

In a real application:

- Initialize once and reuse the service.
- Handle exceptions and returned `false`.
- Serialize connection operations.
- Disconnect before changing cores or modes.
- Provide your own UI and connection credentials.

`any_core_vpn` is an integration library, not a VPN server or credential provider.

The current API spelling is `sellectedConnectionMode`. The factory does not detect the operating system automatically; passing `null` selects Android.

## Common workflows

| Workflow | API / guide |
| --- | --- |
| Connect using a supported share link | `connect(link)` — [unified API](docs/unified_api.md) |
| Connect using compatible core JSON | `connectViaConfig(config)` — [configuration](docs/configuration.md) |
| Save and manage connection keys | `VpnKeyStorageService` — [key storage](docs/key_storage.md) |
| Customize generated configuration | Platform constructors and builders — [configuration](docs/configuration.md) |
| Create routing profiles | `VpnRulesService` — [routing](docs/routing.md) |
| Investigate startup failures | `logStream` and diagnostics — [troubleshooting](docs/troubleshooting.md) |

Existing JSON must match the core and the edition's supported capabilities. The shared API does not convert sing-box JSON into Xray JSON.

Platform integration may apply runtime configuration changes.

## Routing, sniffing, and private networks

Create rules for proxy, direct, or block actions and manage named presets with `VpnRulesService`.

Built-in presets include:

- `geo-ru-direct`
- `geo-ru-proxy`
- `geo-tr-direct`
- `geo-gb-direct`

These are curated domain/CIDR presets, not complete country geolocation databases.

**Split tunneling** means different traffic uses different connection paths.

**Sniffing** inspects supported connection metadata to assist routing; it is not general TLS decryption.

Generated configurations provide private-IP handling. Xray geo assets are a separate capability.

The shared `RoutingRule.domainSets` and `ipSets` fields are currently not translated into native geo rules. Use compatible custom configurations where appropriate.

**Privacy note:** `direct` intentionally bypasses the VPN path. Destinations may see the user's ISP-facing IP address.

See [routing](docs/routing.md).

## Windows VPN support and the full edition

Need a Flutter Windows VPN integration with sing-box or Xray?

The full commercial edition provides:

- Windows sing-box integration with system proxy and TUN modes.
- Windows Xray integration with system proxy mode.
- Additional protocol access according to the full-edition matrix.
- Optional update and support subscriptions.
- Custom development and integration assistance.

**Windows functionality is supplied separately; installing this public package does not unlock it.**

[Contact on Telegram](https://t.me/ElfimovAI) ·
[Request access by email](mailto:blamurai.official@gmail.com)

The purchased release and update eligibility are recorded in the commercial agreement. Subscription expiry does not revoke perpetual rights already granted for eligible releases.

Client development, white-label delivery, and competing integration products are governed by the applicable license.

## Documentation

Detailed documentation is in English:

| Guide | Link |
| --- | --- |
| Documentation index | [docs/README.md](docs/README.md) |
| Installation and core setup | [docs/installation.md](docs/installation.md) |
| Unified API and lifecycle | [docs/unified_api.md](docs/unified_api.md) |
| Platforms and connection modes | [docs/platforms.md](docs/platforms.md) |
| Protocols and share links | [docs/protocols.md](docs/protocols.md) |
| Custom configurations | [docs/configuration.md](docs/configuration.md) |
| Key storage | [docs/key_storage.md](docs/key_storage.md) |
| Routing and geo limitations | [docs/routing.md](docs/routing.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Editions and licensing | [docs/licensing.md](docs/licensing.md) |

## Licensing and lawful use

The public edition uses a restricted source-available license:

- [Freemium license](DEMO_LICENSE.md)
- [Common license terms](LICENSE_TERMS.md)

Commercial B2C applications are permitted within the applicable terms and third-party requirements. Client development and white-label projects require prior written authorization.

Public forks must preserve the applicable restrictions, notices, and required attribution. The license is not an OSI-approved open-source license.

Third-party components retain their own licenses. The custom license does not override sing-box GPL or Xray MPL requirements.

**Android/libbox distribution requires a compatible licensing basis.** Public source alone does not make proprietary restrictions compatible with a GPL-covered combined application.

Developers and operators are responsible for determining whether their applications and activities comply with applicable law. Availability of the plugin is not legal approval for a particular use. Liability is limited only to the extent permitted by law.

## Limitations

- Windows is not included in the public package.
- VMess, Trojan, WireGuard, and SSH are outside freemium protocol access.
- iOS VPN operations are unimplemented.
- macOS requires native ARM64 without Rosetta.
- Core support does not guarantee every generated configuration or transport option.
- Routing changes do not automatically reconnect every application.
- `isRunning()` is not an end-to-end connectivity test.
- No built-in kill switch or guaranteed DNS/IPv6 leak protection is claimed.

## Contributions and acknowledgements

Questions, bug reports, and pull requests are welcome.

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Contributor Agreement](CONTRIBUTOR_AGREEMENT.md) before submitting code.

Accepted contributors receive credit. Contribution alone does not grant commercial access, royalties, or license exceptions.

Thanks to the upstream core developers and dependency authors.

This is an independent integration project, not an official upstream product.

## Contact and custom VPN development

The developer is open to questions and available for:

- Custom Flutter VPN client development.
- Plugin changes for special requirements.
- Routing and configuration work.
- Windows/full-edition access.
- Update and support subscriptions.
- B2B and white-label authorization.

| Contact | Link |
| --- | --- |
| Developer on Telegram | [@ElfimovAI](https://t.me/ElfimovAI) |
| Email | [blamurai.official@gmail.com](mailto:blamurai.official@gmail.com) |
| Plugin news and updates | [t.me/any_core_vpn](https://t.me/any_core_vpn) |

When reporting a problem, include the plugin version, OS, core version, connection mode, and reproduction steps.

Remove passwords, private keys, live connection links, and customer data before sharing logs or configurations.