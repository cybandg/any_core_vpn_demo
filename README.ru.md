# any_core_vpn — Flutter VPN-плагин для sing-box и Xray

**Единый Dart API для sing-box (singbox) и Xray-core. Создавайте Flutter VPN-клиенты для Android и Apple Silicon macOS с публичной freemium-редакцией. Windows доступна отдельно в коммерческой версии.**

`any_core_vpn` упрощает разработку VPN-клиентов: предоставляет общий интерфейс подключения для двух сетевых ядер, работу с поддерживаемыми ссылками и JSON-конфигурациями, сохранение ключей и управление маршрутизацией.

Этот пакет — **публичная demo / freemium-редакция**.

[English README](README.md) ·
[ВАЖНО! перед использованием (Установка)](#установка) ·
[Документация](docs/README.md) ·
[Полная версия](#windows-и-полная-коммерческая-версия) ·
[Лицензия](DEMO_LICENSE.md) ·
[Новости](https://t.me/any_core_vpn) ·
[Связь с разработчиком](#связь-с-разработчиком)

## Возможности

| Возможность | Что предоставляет |
| --- | --- |
| Единый Dart API | Инициализация, подключение, отключение и проверка работы через `VpnService`. |
| sing-box и Xray | Два ядра с общим базовым интерфейсом подключения. |
| Подключение по ссылке | Протоколы, включённые в freemium-редакцию. |
| Готовые конфигурации | `connectViaConfig()` для совместимого JSON в пределах возможностей редакции. |
| Подготовка ядер | Сборка Android-библиотек и установка macOS-ядер. |
| Настройка версий | `setup_cores.json` и аргументы setup-команд. |
| Генераторы конфигураций | Настройка поддерживаемых TUN, DNS, routing, inbounds и outbounds. |
| Хранение ключей | `VpnKeyStorageService` использует `flutter_secure_storage`. |
| Пресеты маршрутизации | Правила proxy, direct и block. |
| Sniffing | Анализ поддерживаемых метаданных соединения для routing. |
| Диагностика | Логи и доступные платформенные методы. |

**Единый API не означает одинаковые возможности ядер.** Параметры конфигурации, режимы и протоколы зависят от платформы, ядра и редакции.

## Доступность платформ

| Платформа | Публичный freemium-пакет | Полная коммерческая версия | Режимы и особенности |
| --- | --- | --- | --- |
| Android | ✅ Доступна публично | ✅ Доступна | sing-box и Xray: TUN и `systemProxy` через HEV. Оба режима требуют VPN-разрешение. |
| macOS — Apple Silicon ARM64 | ✅ Доступна публично | ✅ Доступна | sing-box и Xray: system proxy и TUN. Только native ARM64, без Rosetta. |
| Windows | 🔒 Не включена — [запросить доступ](https://t.me/ElfimovAI) | ✅ Доступна отдельно | sing-box: system proxy и TUN. Xray: только system proxy. |
| iOS | 🚧 Пока недоступна | 🚧 Приоритетная разработка | VPN-операции ещё не реализованы. |
| Linux / Web | ❌ Backend отсутствует | ❌ Backend отсутствует | Сейчас не поддерживаются. |

### Режимы подключения

- **TUN** — виртуальный сетевой интерфейс для маршрутизации IP-трафика.
- **System proxy на desktop** — прокси-путь для приложений, учитывающих соответствующие системные настройки. Он не покрывает автоматически весь трафик.
- **HEV на Android** — tun2socks-компонент, передающий трафик VPN-интерфейса в SOCKS listener ядра. Это не просто установка глобального прокси.

В Dart API используются `ConnectionMode.systemProxy` и `ConnectionMode.tunnel`.

Текущая macOS-интеграция использует `osascript` для административных операций и допускает запуск через установленный sudo wrapper.

## Доступность протоколов

В публичной редакции доступны **VLESS, Shadowsocks, Hysteria2 и TUIC** с учётом возможностей выбранного ядра.

| Протокол | sing-box во freemium | Xray-core во freemium | Полная версия |
| --- | --- | --- | --- |
| VLESS | ✅ Доступен | ✅ Доступен | ✅ Доступен |
| Shadowsocks | ✅ Доступен | ✅ Доступен | ✅ Доступен |
| Hysteria2 | ✅ Доступен | ❌ Не поддерживается ядром | ✅ Доступен через sing-box |
| TUIC | ✅ Доступен | ❌ Не поддерживается ядром | ✅ Доступен через sing-box |
| VMess | 🔒 Только полная версия | 🔒 Только полная версия | Поддержка заявлена — [связаться](https://t.me/ElfimovAI) |
| Trojan | 🔒 Только полная версия | 🔒 Только полная версия | Поддержка заявлена — [связаться](https://t.me/ElfimovAI) |
| WireGuard | 🔒 Только полная версия | 🔒 Только полная версия | Поддержка заявлена с ограничениями интеграции — [связаться](https://t.me/ElfimovAI) |
| SSH | 🔒 Только полная версия | ❌ Не поддерживается ядром | Поддержка заявлена через sing-box — [связаться](https://t.me/ElfimovAI) |

**Покупка полной версии не добавляет ядру отсутствующие протоколы.** Для Hysteria2, TUIC и SSH используется sing-box.

Поддержка протокола не гарантирует работу всех транспортов, форматов ссылок, способов аутентификации и параметров.

Ограничения:

- Desktop-сценарии подключения по ссылке отклоняют внешние Shadowsocks-плагины.
- Текущий sing-box WireGuard-сценарий по ссылке на Windows/macOS в полной версии отклоняет legacy-конфигурацию.
- Готовый JSON не предоставляет неограниченного доступа к функциям, исключённым из freemium.

Подробнее: [протоколы и ссылки](docs/protocols.md).

## Целевые версии ядер

| Ядро | Параметр | Версия по умолчанию |
| --- | --- | --- |
| Xray-core | `xrayVersion` | `26.7.28` |
| sing-box | `singboxVersion` | `1.14.2` |

Это цели совместимости проекта, а не утверждение о последних стабильных upstream-релизах.

Версии можно изменить в:

```text
<plugin_root>/setup_cores.json
```

Аргументы setup-команд позволяют переопределять значения. Другая версия может потребовать обновления конфигураций или нативной интеграции.

## Установка

### 1. Добавьте Flutter-зависимость

В каталоге приложения:

```bash
flutter pub add any_core_vpn
flutter pub get
```

### 2. Подготовьте ядра

**Одной Dart-зависимости недостаточно.**

#### Android

Сборка и установка `libbox.aar` и `libXray.aar`:

```bash
flutter pub run any_core_vpn:setup_android_cores
```

#### macOS

Подготовка ARM64-ядер sing-box и Xray и компиляция Swift helper:

```bash
flutter pub run any_core_vpn:setup_macos_cores
```

#### Все доступные команды

```bash
flutter pub run any_core_vpn:help
```

Также можно использовать:

```bash
dart run any_core_vpn:help
```

**Windows setup не входит в публичную редакцию.** Инструкции предоставляются вместе с коммерческим доступом.

### 3. Проверьте окружение и разрешения

- Android: Git, Python, совместимый Go, JDK, Android SDK и NDK.
- macOS: native Apple Silicon, Xcode command-line tools, `tar` и `ditto`.
- Обработайте отказ в Android VPN-разрешении и запрос административного доступа macOS.
- Пересобирайте приложение после изменения упакованных ядер.
- Проверяйте routing и DNS на целевых устройствах.

Подробнее: [установка](docs/installation.md).

## Быстрый старт

Полный пример библиотеки приложения:

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

Передавайте действительную ссылку VLESS, Shadowsocks, Hysteria2 или TUIC, совместимую с выбранным ядром.

Для Xray выберите `VpnCore.xray` и доступный ему протокол. Для TUN — `ConnectionMode.tunnel`.

В реальном приложении:

- Инициализируйте сервис один раз.
- Обрабатывайте исключения и результат `false`.
- Не выполняйте операции подключения параллельно.
- Отключайтесь перед сменой ядра или режима.
- Реализуйте собственный UI и предоставьте реальные данные подключения.

Плагин не предоставляет VPN-серверы или учётные данные.

Текущее имя свойства API — `sellectedConnectionMode`. Переданный фабрике `null` выбирает Android, а не определяет ОС.

## Основные сценарии

| Сценарий | API / руководство |
| --- | --- |
| Подключение по ссылке | `connect(link)` — [Unified API](docs/unified_api.md) |
| Совместимый готовый JSON | `connectViaConfig(config)` — [Configuration](docs/configuration.md) |
| Сохранение ключей | `VpnKeyStorageService` — [Key storage](docs/key_storage.md) |
| Настройка генерации | Конструкторы платформ и builders — [Configuration](docs/configuration.md) |
| Пресеты маршрутизации | `VpnRulesService` — [Routing](docs/routing.md) |
| Диагностика | `logStream` — [Troubleshooting](docs/troubleshooting.md) |

JSON должен соответствовать ядру и возможностям редакции. Единый API не преобразует sing-box-конфигурацию в Xray-конфигурацию.

Платформенная интеграция может применять runtime-изменения.

## Routing, sniffing и private-сети

Используйте действия proxy, direct и block и управляйте именованными пресетами через `VpnRulesService`.

Встроенные пресеты:

- `geo-ru-direct`
- `geo-ru-proxy`
- `geo-tr-direct`
- `geo-gb-direct`

Это curated-списки доменов/CIDR, а не полные базы геолокации стран.

**Split tunneling** — разные пути для разных потоков трафика.

**Sniffing** — анализ поддерживаемых метаданных соединения для routing, а не универсальная расшифровка TLS.

Генерируемые конфигурации предусматривают private-IP handling. Geo assets для Xray — отдельная возможность.

`RoutingRule.domainSets` и `ipSets` сейчас не переводятся общей моделью в native geo-правила. При необходимости используйте совместимый готовый конфиг.

**Важно:** `direct` намеренно обходит VPN. Адрес назначения может увидеть внешний IP пользователя от его провайдера.

Подробнее: [Routing](docs/routing.md).

## Windows и полная коммерческая версия

Нужна Flutter Windows VPN-интеграция с sing-box или Xray?

Полная редакция предоставляет:

- Windows sing-box: system proxy и TUN.
- Windows Xray: system proxy.
- Дополнительные протоколы согласно таблице полной редакции.
- Подписку на обновления и поддержку по соглашению.
- Заказную разработку и помощь с интеграцией.

**Windows предоставляется отдельно. Установка публичного пакета её не открывает.**

[Запросить доступ в Telegram](https://t.me/ElfimovAI) ·
[Написать на почту](mailto:blamurai.official@gmail.com)

Купленный релиз и доступ к обновлениям фиксируются в коммерческом соглашении. Окончание подписки не отменяет постоянные права, уже предоставленные на разрешённые релизы.

Заказная разработка, white-label и конкурирующие интеграционные продукты регулируются применимой лицензией.

## Документация

Подробная документация — на английском:

| Раздел | Ссылка |
| --- | --- |
| Оглавление | [docs/README.md](docs/README.md) |
| Установка и setup | [docs/installation.md](docs/installation.md) |
| Единый API | [docs/unified_api.md](docs/unified_api.md) |
| Платформы и режимы | [docs/platforms.md](docs/platforms.md) |
| Протоколы | [docs/protocols.md](docs/protocols.md) |
| Конфигурации | [docs/configuration.md](docs/configuration.md) |
| Хранение ключей | [docs/key_storage.md](docs/key_storage.md) |
| Routing и geo | [docs/routing.md](docs/routing.md) |
| Диагностика | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Лицензирование | [docs/licensing.md](docs/licensing.md) |

## Лицензия и законное использование

Публичная редакция использует ограничительную source-available лицензию:

- [Freemium license](DEMO_LICENSE.md)
- [Общие условия](LICENSE_TERMS.md)

Собственные коммерческие B2C-приложения разрешены в пределах условий и сторонних требований. Заказная разработка и white-label требуют предварительного письменного согласования.

Публичные форки должны сохранять ограничения, notices и обязательную атрибуцию. Лицензия не является OSI-approved open-source лицензией.

Сторонние компоненты сохраняют свои условия. Лицензия проекта не отменяет GPL sing-box и MPL Xray.

**Для распространения Android/libbox-связки нужно совместимое основание лицензирования.** Публичные исходники сами по себе не делают ограничения совместимыми с GPL-covered объединённым приложением.

Разработчики и операторы самостоятельно проверяют законность своих продуктов и действий. Доступность плагина не является юридическим разрешением на конкретное применение. Ответственность ограничивается только в допускаемых законом пределах.

## Ограничения

- Windows не включена в публичный пакет.
- VMess, Trojan, WireGuard и SSH не входят в freemium-доступ.
- VPN-операции iOS не реализованы.
- macOS требует native ARM64 без Rosetta.
- Поддержка ядра не гарантирует работу всех вариантов конфигурации.
- Изменение routing не вызывает универсального auto-reconnect.
- `isRunning()` не проверяет доступность интернета.
- Не заявлены встроенный kill switch и гарантированная защита от DNS/IPv6-утечек.

## Вклад и благодарности

Вопросы, отчёты об ошибках и PR приветствуются.

Перед отправкой кода прочитайте [CONTRIBUTING.md](CONTRIBUTING.md) и [Contributor Agreement](CONTRIBUTOR_AGREEMENT.md).

Авторы принятых вкладов получают благодарность. Вклад не предоставляет автоматический коммерческий доступ, роялти или исключения из лицензии.

Спасибо разработчикам upstream-ядер и зависимостей.

Проект является независимой интеграцией, а не официальным продуктом upstream.

## Связь с разработчиком

Разработчик открыт к вопросам и готов обсудить:

- Разработку Flutter VPN-клиента на заказ.
- Доработку плагина под специальные требования.
- Routing и конфигурации.
- Windows и доступ к полной редакции.
- Подписку на обновления и поддержку.
- B2B и white-label разрешения.

| Контакт | Ссылка |
| --- | --- |
| Telegram разработчика | [@ElfimovAI](https://t.me/ElfimovAI) |
| Почта | [blamurai.official@gmail.com](mailto:blamurai.official@gmail.com) |
| Новости плагина | [t.me/any_core_vpn](https://t.me/any_core_vpn) |

При сообщении о проблеме укажите версию плагина, ОС, ядро, режим и шаги воспроизведения.

Перед отправкой удалите пароли, приватные ключи, действующие ссылки подключения и данные заказчиков.