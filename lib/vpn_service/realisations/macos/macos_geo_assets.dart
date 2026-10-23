import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

/// Ships the minimal geo databases for Xray on macOS and caches them on disk.
///
/// WHY DISK AT ALL: Xray is an EXTERNAL process — it cannot read the Flutter
/// asset bundle, it only accepts a filesystem directory via the config-root
/// env "xray.location.asset". Its built-in fallback (the executable's own
/// directory) is useless here: the binary lives in the cores bundle or in the
/// pinned root dir, neither ships geo data.
///
/// Source order:
///  1. Plugin asset bundle (offline-first, version pinned to the app build).
///  2. Network download (fallback when the asset is missing, and the future
///     hook for geo auto-refresh).
///
/// Minimal set, same as Android: dlc.dat as geosite.dat (~2 MB) and
/// private.dat as geoip.dat (240 bytes, geoip:private only).
class MacosGeoAssets {
  MacosGeoAssets._();

  static const String geositeUrl =
      'https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat';
  static const String geoipUrl =
      'https://github.com/v2fly/geoip/releases/latest/download/private.dat';

  /// Asset keys inside the host app bundle: plugin assets are always prefixed
  /// with "packages/<plugin_name>/".
  static const Map<String, String> _bundled = {
    'geosite.dat': 'packages/any_core_vpn/assets/geo/geosite.dat',
    'geoip.dat': 'packages/any_core_vpn/assets/geo/geoip.dat',
  };

  static const Map<String, String> _remote = {
    'geosite.dat': geositeUrl,
    'geoip.dat': geoipUrl,
  };

  /// <home>/Library/Application Support/any_core_vpn/geo
  static Future<Directory> directory() async {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME is not set');
    }
    return Directory(
      p.join(home, 'Library', 'Application Support', 'any_core_vpn', 'geo'),
    );
  }

  /// Returns the geo dir when BOTH databases are present, or null when
  /// unavailable — the caller then skips the env injection and the core falls
  /// back to its default (failing) lookup with a clear error.
  static Future<String?> ensure({void Function(String message)? log}) async {
    try {
      final dir = await directory();
      await dir.create(recursive: true);

      for (final name in _bundled.keys) {
        final file = File(p.join(dir.path, name));
        if (await file.exists() && await file.length() > 0) continue;

        if (await _extractFromBundle(name, file, log)) continue;

        final url = _remote[name]!;
        log?.call('geo $name not in bundle — downloading $url …');
        await _download(url, file);
        log?.call('geo downloaded: ${file.path} (${await file.length()} bytes)');
      }
      return dir.path;
    } catch (error) {
      log?.call('geo assets unavailable: $error');
      return null;
    }
  }

  /// Unpacks one file from the Flutter asset bundle onto disk.
  static Future<bool> _extractFromBundle(
    String name,
    File target,
    void Function(String message)? log,
  ) async {
    try {
      final ByteData data = await rootBundle.load(_bundled[name]!);
      final bytes = data.buffer.asUint8List();
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      log?.call('geo extracted from plugin assets: ${target.path} (${'${bytes.length}'} bytes)');
      return true;
    } catch (error) {
      log?.call('geo asset $name unreadable from bundle: $error');
      return false;
    }
  }

  static Future<void> _download(String url, File target) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url))
      ..followRedirects = true
      ..maxRedirects = 5;
      final response =
          await request.close().timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }
      final tmp = File('${target.path}.tmp');
      await response.pipe(tmp.openWrite());
      if (await tmp.length() == 0) {
        await tmp.delete();
        throw HttpException('empty body for $url');
      }
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } finally {
      client.close(force: true);
    }
  }
}