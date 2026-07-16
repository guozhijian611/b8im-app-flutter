import 'dart:convert';

final class AppEnvironment {
  const AppEnvironment({
    required this.discoveryBaseUri,
    required this.routingPublicKeys,
    this.initialEnterpriseCode = '',
  });

  factory AppEnvironment.fromCompileTime() {
    const discoveryBaseUrl = String.fromEnvironment(
      'B8IM_DISCOVERY_BASE_URL',
      defaultValue: 'https://api.idev.love',
    );
    const routingPublicKeysJson = String.fromEnvironment(
      'B8IM_ROUTING_PUBLIC_KEYS',
      defaultValue: '{}',
    );
    const initialEnterpriseCode = String.fromEnvironment(
      'B8IM_ENTERPRISE_CODE',
    );

    return AppEnvironment(
      discoveryBaseUri: _secureBaseUri(discoveryBaseUrl),
      routingPublicKeys: _decodeKeys(routingPublicKeysJson),
      initialEnterpriseCode: initialEnterpriseCode.trim().toLowerCase(),
    );
  }

  final Uri discoveryBaseUri;
  final Map<String, String> routingPublicKeys;
  final String initialEnterpriseCode;

  static Uri _secureBaseUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException(
        'B8IM_DISCOVERY_BASE_URL 必须是无凭据、查询参数和片段的 HTTPS 地址',
      );
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  static Map<String, String> _decodeKeys(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('B8IM_ROUTING_PUBLIC_KEYS 必须是 JSON 对象');
    }
    final keys = <String, String>{};
    for (final entry in decoded.entries) {
      final key = entry.key.trim();
      final encoded = entry.value;
      if (key.isEmpty || encoded is! String || encoded.trim().isEmpty) {
        throw const FormatException('B8IM_ROUTING_PUBLIC_KEYS 包含无效公钥');
      }
      keys[key] = encoded.trim();
    }
    return Map.unmodifiable(keys);
  }
}
