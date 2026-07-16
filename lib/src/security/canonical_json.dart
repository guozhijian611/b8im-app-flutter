import 'dart:convert';

String canonicalJson(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return jsonEncode(value);
  }
  if (value is List<Object?>) {
    return '[${value.map(canonicalJson).join(',')}]';
  }
  if (value is Map) {
    final entries =
        value.entries
            .map((entry) => MapEntry(entry.key.toString(), entry.value))
            .toList()
          ..sort((left, right) => left.key.compareTo(right.key));
    return '{${entries.map((entry) => '${jsonEncode(entry.key)}:${canonicalJson(entry.value)}').join(',')}}';
  }
  throw FormatException('不支持的签名载荷类型: ${value.runtimeType}');
}
