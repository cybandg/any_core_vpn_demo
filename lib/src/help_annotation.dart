/// Metadata annotation for plugin CLI scripts in bin/.
///
/// Annotate the top-level `main` of any bin/<command>.dart file:
///
///   @HelpAnnotation(
///     'Short description of the command',
///     args: [
///       ['--flag <value>', 'what the flag does'],
///       ['ENV_VAR (env)', 'environment variable description'],
///     ],
///     order: 10,
///   )
///   Future<void> main(List<String> argv) async { ... }
///
/// `dart run any_core_vpn:help` scans all bin/*.dart sources and prints
/// these descriptions as a unified help page, sorted by [order]
/// (lower = earlier, default 100), then alphabetically.
///
/// Note: annotations are NOT readable at runtime from other files
/// (no dart:mirrors in CLI/Flutter), so help.dart parses the source text.
/// Keep the annotation as plain const literals (strings and lists only).
class HelpAnnotation {
  /// Short description of the command.
  final String description;

  /// Pairs of [argument, description]. May be empty.
  final List<List<String>> args;

  /// Display order in the help page. Lower values come first.
  /// Default is 100; use 0 for help itself, 10/20/... for the rest.
  final int order;

  const HelpAnnotation(
    this.description, {
    this.args = const [],
    this.order = 100,
  });
}