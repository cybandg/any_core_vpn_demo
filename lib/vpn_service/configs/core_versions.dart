/// Core versions reported by the platform, used for feature gating.
///
/// A null version means "unknown yet" (on Android the Xray version is only
/// known after the :xraycore process has reported it). Version-gated checks
/// must degrade to INFO in that case - never to a false ERROR.
library;

class CoreVersions {
  const CoreVersions({this.xray, this.singbox});

  final String? xray;
  final String? singbox;

  bool get isEmpty => xray == null && singbox == null;

  /// "26.7.28" -> 260728. Non-numeric suffixes are ignored.
  static int? versionKey(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;

    final cleaned = raw.trim().replaceAll(RegExp(r'^v'), '');
    final parts = cleaned.split(RegExp(r'[.\-+]'));
    if (parts.length < 2) return null;

    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
    if (major == null || minor == null) return null;

    return major * 10000 + minor * 100 + patch;
  }

  bool xrayAtLeast(int major, int minor, [int patch = 0]) {
    final key = versionKey(xray);
    if (key == null) return false;
    return key >= major * 10000 + minor * 100 + patch;
  }

  bool singboxAtLeast(int major, int minor, [int patch = 0]) {
    final key = versionKey(singbox);
    if (key == null) return false;
    return key >= major * 10000 + minor * 100 + patch;
  }

  /// True when the version string exists but could not be parsed.
  bool get hasUnparsable =>
      (xray != null && versionKey(xray) == null) ||
      (singbox != null && versionKey(singbox) == null);

  String describe() {
    final parts = <String>[
      'xray: ${xray ?? 'unknown'}',
      'singbox: ${singbox ?? 'unknown'}',
    ];
    return parts.join(' · ');
  }

  @override
  String toString() => 'CoreVersions(${describe()})';
}
