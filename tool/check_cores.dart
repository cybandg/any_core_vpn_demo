#!/usr/bin/env dart
//
// check_cores.dart
// Checks the latest stable and pre-release versions of Xray-core and sing-box
// on GitHub and compares them with xrayVersion / singboxVersion
// from setup_cores.json in the project root.
//
// Usage:
//   dart run tool/check_cores.dart
//   GITHUB_TOKEN=xxx dart run tool/scripts/check_cores.dart   (higher rate limit)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const xrayRepo = 'XTLS/Xray-core';
const singboxRepo = 'SagerNet/sing-box';

Never fail(String m) {
  stderr.writeln('ERROR: $m');
  exit(1);
}

/// GET request to the GitHub API. Returns decoded JSON.
Future<dynamic> apiGet(String url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('User-Agent', 'singbox-xray-vpn-flutter-check');
    final token = Platform.environment['GITHUB_TOKEN'];
    if (token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final response = await request.close().timeout(const Duration(seconds: 60));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      fail('GitHub API returned ${response.statusCode} for $url\n$body');
    }
    return jsonDecode(body);
  } on SocketException catch (e) {
    fail('network error while requesting $url: $e');
  } on TimeoutException {
    fail('timeout while requesting $url');
  } finally {
    client.close(force: true);
  }
}

String stripV(String tag) => tag.replaceFirst(RegExp('^v'), '');

/// latest stable = /releases/latest (GitHub already excludes drafts and prereleases)
Future<String> latestStable(String repo) async {
  final data = await apiGet('https://api.github.com/repos/$repo/releases/latest');
  if (data is Map && data['tag_name'] is String) {
    return stripV(data['tag_name'] as String);
  }
  return '';
}

/// latest pre-release = first entry with prerelease==true in the recent releases list
Future<String> latestPrerelease(String repo) async {
  final data =
      await apiGet('https://api.github.com/repos/$repo/releases?per_page=30');
  if (data is List) {
    for (final r in data) {
      if (r is Map && r['draft'] == false && r['prerelease'] == true) {
        final tag = r['tag_name'];
        if (tag is String && tag.isNotEmpty) return stripV(tag);
      }
    }
  }
  return '';
}

Future<void> main(List<String> argv) async {
  final scriptDir = File.fromUri(Platform.script).parent; // <root>/tool
  final projectRoot = scriptDir.parent;                   // <root>
  final sep = Platform.pathSeparator;
  final configFile = Platform.environment['CONFIG_FILE'] ??
      '${projectRoot.path}${sep}setup_cores.json';

  final file = File(configFile);
  if (!file.existsSync()) fail('config file not found: $configFile');

  Map<String, dynamic> config;
  try {
    config = Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()));
  } catch (e) {
    fail('cannot parse $configFile: $e');
  }

  String jsonGet(String key) {
    final v = config[key];
    return v is String ? v : '';
  }

  final currentXray = jsonGet('xrayVersion');
  final currentSingbox = jsonGet('singboxVersion');
  if (currentXray.isEmpty) fail('xrayVersion is empty in $configFile');
  if (currentSingbox.isEmpty) fail('singboxVersion is empty in $configFile');

  final stableXray = await latestStable(xrayRepo);
  final stableSingbox = await latestStable(singboxRepo);

  var preXray = await latestPrerelease(xrayRepo);
  var preSingbox = await latestPrerelease(singboxRepo);
  if (preXray.isEmpty) preXray = '-';
  if (preSingbox.isEmpty) preSingbox = '-';

  stdout.writeln('actual stable versions - xray: $stableXray, singbox: $stableSingbox');
  stdout.writeln('actual pre-release versions - xray: $preXray, singbox: $preSingbox');

  final outdated = <String>[];
  if (currentXray != stableXray) outdated.add('xray: $stableXray');
  if (currentSingbox != stableSingbox) outdated.add('singbox: $stableSingbox');

  if (outdated.isEmpty) {
    stdout.writeln("you don't need to update setup_cores.json");
  } else {
    stdout.writeln(
        'you need to update your plugin cause new version(s) of (${outdated.join(' and/or ')}) is available');
  }
}