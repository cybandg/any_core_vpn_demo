// Shared helpers for the macOS cores scripts.
// Pure dart:io / dart:convert - NO package: imports, so these scripts can be
// executed as `dart <file>.dart` even without `pub get` (needed by Xcode
// build phases).

import 'dart:convert';
import 'dart:io';

final String sep = Platform.pathSeparator;

// ---------- logging ----------
void log(String m) => stdout.writeln('==> $m');
void note(String m) => stdout.writeln('    $m');
void warn(String m) => stdout.writeln('WARNING: $m');
Never fail(String m) {
  stderr.writeln('ERROR: $m');
  exit(1);
}

// ---------- small utils ----------
String baseName(String path) =>
    path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;

String humanSize(int bytes) {
  const units = ['B', 'K', 'M', 'G', 'T'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final digits = (v < 10 && i > 0) ? 1 : 0;
  return '${v.toStringAsFixed(digits)}${units[i]}';
}

/// Recursively searches for a file named [fileName] under [root].
File? findFirst(String root, String fileName, {int maxDepth = 1 << 30}) {
  final dir = Directory(root);
  if (!dir.existsSync()) return null;

  File? walk(Directory d, int depth) {
    if (depth > maxDepth) return null;
    final entries = d.listSync();
    for (final e in entries) {
      if (e is File && baseName(e.path) == fileName) return e;
    }
    for (final e in entries) {
      if (e is Directory) {
        if (baseName(e.path) == '.git') continue;
        final r = walk(e, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  return walk(dir, 1);
}

// ---------- pure-Dart SHA-256 (streaming) ----------
const List<int> _sha256K = [
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;

/// Incremental SHA-256 so big files can be hashed chunk by chunk.
class Sha256 {
  final List<int> _h = [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final List<int> _buf = [];
  int _totalLen = 0;

  void add(List<int> data) {
    _buf.addAll(data);
    _totalLen += data.length;
    var off = 0;
    while (_buf.length - off >= 64) {
      _process(off);
      off += 64;
    }
    if (off > 0) _buf.removeRange(0, off);
  }

  void _process(int off) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] =
          (_buf[off + i * 4] << 24) |
          (_buf[off + i * 4 + 1] << 16) |
          (_buf[off + i * 4 + 2] << 8) |
          _buf[off + i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = _h[0], b = _h[1], c = _h[2], d = _h[3];
    var e = _h[4], f = _h[5], g = _h[6], hh = _h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (hh + s1 + ch + _sha256K[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    _h[0] = (_h[0] + a) & 0xffffffff;
    _h[1] = (_h[1] + b) & 0xffffffff;
    _h[2] = (_h[2] + c) & 0xffffffff;
    _h[3] = (_h[3] + d) & 0xffffffff;
    _h[4] = (_h[4] + e) & 0xffffffff;
    _h[5] = (_h[5] + f) & 0xffffffff;
    _h[6] = (_h[6] + g) & 0xffffffff;
    _h[7] = (_h[7] + hh) & 0xffffffff;
  }

  String finish() {
    final bitLen = _totalLen * 8;
    _buf.add(0x80);
    while (_buf.length % 64 != 56) {
      _buf.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      _buf.add((bitLen >> (8 * i)) & 0xff);
    }
    for (var off = 0; off < _buf.length; off += 64) {
      _process(off);
    }
    return _h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
  }
}

String sha256Hex(List<int> data) => (Sha256()..add(data)).finish();

/// Hashes a file in 1 MiB chunks (no full load into memory).
///
/// NOTE: do NOT use File.openRead(chunkSize) - its first positional parameter
/// is the START BYTE OFFSET, not a chunk size, so openRead(1 << 20) silently
/// skips the first megabyte. RandomAccessFile.read() is the correct API for
/// chunked reading.
Future<String> sha256OfFile(File f) async {
  const chunkSize = 1024 * 1024;
  final h = Sha256();
  final raf = await f.open();
  try {
    while (true) {
      final chunk = await raf.read(chunkSize);
      if (chunk.isEmpty) break;
      h.add(chunk);
    }
  } finally {
    await raf.close();
  }
  return h.finish();
}

/// Guards the hand-rolled SHA-256 against regressions (wrong offset, broken
/// padding, multi-block streaming, etc). Called at setup start; cheap.
void selfTestSha256() {
  const vectors = <String, String>{
    '': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'The quick brown fox jumps over the lazy dog':
        'd7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592',
  };
  vectors.forEach((input, expected) {
    final actual = sha256Hex(utf8.encode(input));
    if (actual != expected) {
      fail(
        'INTERNAL: sha256 self-test failed for "${input.length} bytes": '
        'expected $expected, got $actual',
      );
    }
  });

  // streaming across many blocks must equal the single-shot result
  final streamed = Sha256();
  final block = List<int>.filled(4096, 0x61); // 'a' * 4096
  for (var i = 0; i < 256; i++) {
    // 1 MiB of 'a'
    streamed.add(block);
  }
  final single = sha256Hex(List<int>.filled(1024 * 1024, 0x61));
  if (streamed.finish() != single) {
    fail('INTERNAL: sha256 streaming self-test failed');
  }
}

// ---------- process helpers ----------
Future<int> runStream(String exe, List<String> args, {String? cwd}) async {
  note('\$ $exe ${args.join(' ')}${cwd != null ? '  (in $cwd)' : ''}');
  final p = await Process.start(
    exe,
    args,
    workingDirectory: cwd,
    mode: ProcessStartMode.inheritStdio,
  );
  return p.exitCode;
}

Future<void> runOrDie(
  String exe,
  List<String> args, {
  String? cwd,
  String? error,
}) async {
  final code = await runStream(exe, args, cwd: cwd);
  if (code != 0) fail(error ?? "'$exe ${args.join(' ')}' failed (exit $code)");
}

/// Runs quietly; returns null on failure.
String? runCapture(String exe, List<String> args) {
  try {
    final r = Process.runSync(exe, args);
    if (r.exitCode != 0) return null;
    return (r.stdout as String).trim();
  } catch (_) {
    return null;
  }
}

String? resolveCommand(String cmd) {
  final r = runCapture('which', [cmd]);
  if (r != null && r.isNotEmpty) return r;
  for (final dir in [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
    '/bin',
  ]) {
    final f = File('$dir${sep}$cmd');
    if (f.existsSync()) return f.path;
  }
  return null;
}

void chmod(String path, String mode) {
  final r = Process.runSync('chmod', [mode, path]);
  if (r.exitCode != 0) warn('chmod $mode failed for $path: ${r.stderr}');
}

/// Removes the com.apple.quarantine xattr recursively (best effort).
void clearQuarantine(String path) {
  Process.runSync('xattr', ['-dr', 'com.apple.quarantine', path]);
}

// ---------- http / github ----------
String? get githubToken => Platform.environment['GITHUB_TOKEN'];

Future<HttpClientResponse> _get(String url, {bool json = false}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.getUrl(Uri.parse(url));
    if (json) {
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'any-core-vpn-macos-setup');
      final t = githubToken;
      if (t != null && t.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      }
    }
    req.followRedirects = true;
    req.maxRedirects = 5;
    final res = await req.close().timeout(const Duration(minutes: 10));
    if (res.statusCode != 200) {
      await res.drain<void>();
      fail('HTTP ${res.statusCode} for $url');
    }
    return res;
  } finally {
    // client closed by caller-side drain/subscription completion
  }
}

Future<dynamic> githubGetJson(String url) async {
  final res = await _get(url, json: true);
  final body = await res.transform(utf8.decoder).join();
  try {
    return jsonDecode(body);
  } catch (e) {
    fail('cannot parse JSON from $url: $e');
  }
}

/// Downloads [url] into [out], hashing on the fly. Returns the sha256.
Future<String> downloadAndHash(String url, File out) async {
  final res = await _get(url);
  final h = Sha256();
  var total = 0;
  final sink = out.openWrite();
  try {
    await for (final chunk in res) {
      sink.add(chunk);
      h.add(chunk);
      total += chunk.length;
    }
  } finally {
    await sink.flush();
    await sink.close();
  }
  note('downloaded ${humanSize(total)} -> ${out.path}');
  return h.finish();
}


// ---------- setup_cores.json ----------

typedef LatestTagResolver = Future<String> Function(
    String repo, bool allowPreRelease);

/// Reads <plugin_root>/setup_cores.json (keys: xrayVersion, singboxVersion,
/// optional libxrayRef). Never fails: missing file / keys yield empty strings
/// so the caller decides the precedence.
({bool exists, String xray, String singbox, String libxrayRef})
    readSetupCores(String configPath) {
  final f = File(configPath);
  if (!f.existsSync()) {
    return (exists: false, xray: '', singbox: '', libxrayRef: '');
  }
  try {
    final data = jsonDecode(f.readAsStringSync());
    if (data is Map) {
      String s(String k) {
        final v = data[k];
        return v is String ? v.trim() : '';
      }

      return (
        exists: true,
        xray: s('xrayVersion'),
        singbox: s('singboxVersion'),
        libxrayRef: s('libxrayRef'),
      );
    }
  } catch (e) {
    fail('cannot parse $configPath: $e');
  }
  return (exists: true, xray: '', singbox: '', libxrayRef: '');
}

/// Resolves one core version.
/// Precedence: CLI value > setup_cores.json > [latestResolver] > fail.
/// Returns the tag WITH the leading 'v' plus a human-readable source.
Future<({String tag, String source})> resolveCoreVersion({
  required String what,
  required String repo,
  required String cliValue,
  required String configValue,
  required String configPath,
  required bool useLatest,
  required bool allowPreRelease,
  LatestTagResolver? latestResolver,
}) async {
  if (cliValue.isNotEmpty) {
    return (tag: normalizeTag(cliValue), source: 'CLI argument');
  }
  if (configValue.isNotEmpty) {
    return (
      tag: normalizeTag(configValue),
      source: 'setup_cores.json (${baseName(configPath)})',
    );
  }
  if (useLatest && latestResolver != null) {
    final tag = await latestResolver(repo, allowPreRelease);
    return (tag: normalizeTag(tag), source: 'GitHub latest release');
  }
  fail('no version resolved for $what.\n'
      '       Precedence is: CLI flag > setup_cores.json > --latest-versions.\n'
      '       Either pass the version explicitly, or add the key to $configPath:\n'
      '         { "xrayVersion": "26.7.28", "singboxVersion": "1.14.2" }\n'
      '       (expected key: ${what == 'xray' ? 'xrayVersion' : 'singboxVersion'})');
}

String normalizeTag(String v) => v.startsWith('v') ? v : 'v$v';