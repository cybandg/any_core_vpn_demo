// Entry point for: dart run any_core_vpn:help
// Scans all bin/*.dart sources of this package for HelpAnnotation metadata
// and prints a unified help page.
//
// Parsing is structural (no heuristics):
//   - comments are blanked out (marker mentions in comments are ignored)
//   - description = all string literals BEFORE the first '[' outside strings
//   - arguments   = every [name, desc] pair inside the args list,
//                   parsed with a string/bracket-aware scanner
//   - `order: <int>` is extracted for sorting (default 100)

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:any_core_vpn/src/help_annotation.dart';

// MUST match "name:" in this plugin's pubspec.yaml
const packageName = 'any_core_vpn';

// Built by concatenation so this file's own source does not contain the
// literal marker before its real annotation (self-scan safety).
const _marker = '@Help' 'Annotation(';

const _lineWidth = 92;

// ---------- plugin root resolution ----------

Future<String> resolvePluginRoot() async {
  final libUri =
      await Isolate.resolvePackageUri(Uri.parse('package:$packageName/'));
  if (libUri != null) {
    return Directory.fromUri(libUri).parent.path; // <root>/lib -> <root>
  }

  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final cfg = File('${dir.path}/.dart_tool/package_config.json');
    if (cfg.existsSync()) {
      final data = jsonDecode(cfg.readAsStringSync());
      for (final p in (data as Map)['packages'] as List) {
        if (p is Map && p['name'] == packageName && p['rootUri'] is String) {
          final resolved = Uri.file(cfg.absolute.path).resolve(p['rootUri']);
          final root = Directory.fromUri(resolved);
          if (root.existsSync()) return root.absolute.path;
        }
      }
      break;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  stderr.writeln('ERROR: cannot resolve package:$packageName/.');
  stderr.writeln('       Run "flutter pub get" first.');
  exit(1);
}

// ---------- source preprocessing ----------

/// Replaces every comment (// and /* */) with spaces, preserving offsets and
/// keeping string literals intact.
String _blankComments(String src) {
  final sb = StringBuffer();
  var i = 0;
  String? quote;
  var lineComment = false;
  var blockComment = false;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (lineComment) {
      if (c == '\n') {
        lineComment = false;
        sb.write(c);
      } else {
        sb.write(' ');
      }
      i++;
    } else if (blockComment) {
      if (c == '*' && next == '/') {
        blockComment = false;
        sb.write('  ');
        i += 2;
      } else {
        sb.write(c == '\n' ? '\n' : ' ');
        i++;
      }
    } else if (quote != null) {
      if (c == '\\') {
        sb.write(c);
        if (i + 1 < src.length) sb.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      sb.write(c);
      i++;
    } else {
      if (c == '/' && next == '/') {
        lineComment = true;
        sb.write('  ');
        i += 2;
      } else if (c == '/' && next == '*') {
        blockComment = true;
        sb.write('  ');
        i += 2;
      } else if (c == "'" || c == '"') {
        quote = c;
        sb.write(c);
        i++;
      } else {
        sb.write(c);
        i++;
      }
    }
  }
  return sb.toString();
}

/// Extracts the raw argument text of the first real (non-comment)
/// HelpAnnotation in [source]. String- and bracket-aware.
String? _annotationContent(String source) {
  final blanked = _blankComments(source);
  final start = blanked.indexOf(_marker);
  if (start == -1) return null;

  var i = start + _marker.length; // marker's '(' is already consumed
  var depth = 1;
  var inStr = false;
  String? quote;
  var escaped = false;
  final body = StringBuffer();

  while (i < source.length && depth > 0) {
    final c = source[i];
    if (inStr) {
      body.write(c);
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == quote) {
        inStr = false;
      }
    } else {
      if (c == "'" || c == '"') {
        inStr = true;
        quote = c;
        body.write(c);
      } else if (c == '(' || c == '[') {
        depth++;
        body.write(c);
      } else if (c == ')' || c == ']') {
        depth--;
        if (depth > 0) body.write(c); // skip the final ')'
      } else {
        body.write(c);
      }
    }
    i++;
  }
  return depth == 0 ? body.toString() : null;
}

// ---------- string literal extraction ----------

final _literalRe = RegExp('\'((?:[^\'\\\\]|\\\\.)*)\'|"((?:[^"\\\\]|\\\\.)*)"');

String _unescape(String s) => s.replaceAllMapped(
      RegExp(r'\\(.)'),
      (m) => switch (m[1]!) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        "'" => "'",
        '"' => '"',
        r'\' => r'\',
        r'$' => r'$',
        _ => m[1]!,
      },
    );

/// All string literals in [content], in order, WITHOUT merging.
List<String> _stringLiterals(String content) {
  return _literalRe
      .allMatches(content)
      .map((m) => _unescape(m.group(1) ?? m.group(2) ?? ''))
      .toList();
}

// ---------- structural annotation parsing ----------

typedef _Entry = ({String cmd, String desc, List<List<String>> args, int order});

/// Index of the first '[' that is NOT inside a string literal, or -1.
/// Everything before it is the description part, from it on - the args list.
int _argsListStart(String content) {
  var inStr = false;
  String? q;
  var esc = false;
  for (var i = 0; i < content.length; i++) {
    final c = content[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == '\\') {
        esc = true;
      } else if (c == q) {
        inStr = false;
      }
    } else if (c == "'" || c == '"') {
      inStr = true;
      q = c;
    } else if (c == '[') {
      return i;
    }
  }
  return -1;
}

/// Parses [name, desc] pairs from the args list part.
/// Depth-aware: outer list = depth 1, each pair = depth 2.
List<List<String>> _parseArgPairs(String argsPart) {
  final pairs = <List<String>>[];
  var inStr = false;
  String? q;
  var esc = false;
  var depth = 0;
  var groupStart = -1;

  for (var i = 0; i < argsPart.length; i++) {
    final c = argsPart[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == '\\') {
        esc = true;
      } else if (c == q) {
        inStr = false;
      }
      continue;
    }
    if (c == "'" || c == '"') {
      inStr = true;
      q = c;
    } else if (c == '[') {
      depth++;
      if (depth == 2) groupStart = i + 1;
    } else if (c == ']') {
      if (depth == 2 && groupStart >= 0) {
        final lits = _stringLiterals(argsPart.substring(groupStart, i));
        if (lits.length >= 2) {
          pairs.add([lits.first, lits.sublist(1).join(' ')]);
        } else if (lits.length == 1) {
          pairs.add([lits.first, '']);
        }
      }
      depth--;
    }
  }
  return pairs;
}

int _extractOrder(String content) {
  final withoutStrings = content.replaceAll(_literalRe, ' ');
  final m = RegExp(r'order\s*:\s*(-?\d+)').firstMatch(withoutStrings);
  return m == null ? 100 : int.parse(m.group(1)!);
}

_Entry _parseEntry(String cmd, String source) {
  final content = _annotationContent(source);
  if (content == null) {
    return (
      cmd: cmd,
      desc: '(no description - missing HelpAnnotation)',
      args: const [],
      order: 1000,
    );
  }

  final split = _argsListStart(content);
  final descPart = split == -1 ? content : content.substring(0, split);
  final argsPart = split == -1 ? '' : content.substring(split);

  // description: join ALL literals, then normalize whitespace
  final desc = _stringLiterals(descPart)
      .join('')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  return (
    cmd: cmd,
    desc: desc.isEmpty ? '(empty annotation)' : desc,
    args: split == -1 ? const [] : _parseArgPairs(argsPart),
    order: _extractOrder(content),
  );
}

// ---------- pretty printing ----------

List<String> _wrap(String text, int width, String indent) {
  final lines = <String>[];
  for (final paragraph in text.split('\n')) {
    final words = paragraph.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    var line = '';
    for (final w in words) {
      if (line.isEmpty) {
        line = w;
      } else if (line.length + 1 + w.length <= width) {
        line += ' $w';
      } else {
        lines.add('$indent$line');
        line = w;
      }
    }
    if (line.isNotEmpty) lines.add('$indent$line');
  }
  return lines;
}

@HelpAnnotation(
  'Scan all bin/*.dart sources of this package for HelpAnnotation metadata '
  'and print this unified help page. No arguments needed.',
  order: 0,
)
Future<void> main(List<String> argv) async {
  final pluginRoot = await resolvePluginRoot();
  final binDir = Directory('$pluginRoot/bin');

  if (!binDir.existsSync()) {
    stderr.writeln('ERROR: bin dir not found: ${binDir.path}');
    exit(1);
  }

  final files = binDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  final entries = <_Entry>[
    for (final f in files)
      _parseEntry(f.uri.pathSegments.last.replaceAll('.dart', ''),
          f.readAsStringSync()),
  ]..sort((a, b) {
      final c = a.order.compareTo(b.order);
      return c != 0 ? c : a.cmd.compareTo(b.cmd);
    });

  // ---------- print ----------
  final title = '$packageName - CLI commands';
  stdout.writeln(title);
  stdout.writeln('=' * title.length);

  for (final e in entries) {
    stdout.writeln();
    stdout.writeln('  ${e.cmd}');
    stdout.writeln('      \$ dart run $packageName:${e.cmd}');
    for (final line in _wrap(e.desc, _lineWidth - 6, '      ')) {
      stdout.writeln(line);
    }
    if (e.args.isNotEmpty) {
      stdout.writeln();
      stdout.writeln('      Arguments / env:');
      for (final a in e.args) {
        stdout.writeln('        ${a[0]}');
        if (a[1].isNotEmpty) {
          for (final line in _wrap(a[1], _lineWidth - 10, '          ')) {
            stdout.writeln(line);
          }
        }
      }
    }
  }

  stdout.writeln();
  stdout.writeln('Commands are defined via HelpAnnotation metadata in bin/*.dart.');
}