import 'dart:math';

final class TraceContext {
  TraceContext._(this.traceId, this.spanId, this.traceFlags);

  factory TraceContext.root({Random? random}) {
    final source = random ?? Random.secure();
    return TraceContext._(
      _nonZeroHex(16, source),
      _nonZeroHex(8, source),
      '01',
    );
  }

  factory TraceContext.parse(String value) {
    final match = RegExp(
      r'^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$',
    ).firstMatch(value.trim().toLowerCase());
    if (match == null ||
        _allZero(match.group(1)!) ||
        _allZero(match.group(2)!)) {
      throw const FormatException('traceparent 格式无效');
    }
    return TraceContext._(match.group(1)!, match.group(2)!, match.group(3)!);
  }

  final String traceId;
  final String spanId;
  final String traceFlags;

  String get traceparent => '00-$traceId-$spanId-$traceFlags';

  TraceContext child({Random? random}) => TraceContext._(
    traceId,
    _nonZeroHex(8, random ?? Random.secure()),
    traceFlags,
  );

  Map<String, String> injectHttp([Map<String, String>? headers]) => {
    ...?headers,
    'traceparent': traceparent,
  };

  Map<String, Object?> injectImEnvelope(Map<String, Object?> envelope) => {
    ...envelope,
    'traceparent': traceparent,
  };

  static bool _allZero(String value) => RegExp(r'^0+$').hasMatch(value);

  static String _nonZeroHex(int bytes, Random random) {
    while (true) {
      final value = List<int>.generate(
        bytes,
        (_) => random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      if (!_allZero(value)) return value;
    }
  }
}
