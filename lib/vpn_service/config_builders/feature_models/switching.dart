part of '../core_config_builder.dart';

enum OutboundGroupType {
  selector,
  urlTest,
  fallback,
  roundRobin,
  random,
}

class OutboundGroup {
  final String tag;
  final OutboundGroupType type;
  final List<String> outboundTags;
  final String testUrl;
  final Duration interval;
  final Duration tolerance;

  const OutboundGroup({
    required this.tag,
    required this.type,
    required this.outboundTags,
    this.testUrl = "http://cp.cloudflare.com/generate_204",
    this.interval = const Duration(minutes: 3),
    this.tolerance = const Duration(milliseconds: 50),
  });
}