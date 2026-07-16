import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'canonical_json.dart';

final class RoutingSignatureVerifier {
  RoutingSignatureVerifier(Map<String, String> trustedKeys)
    : _trustedKeys = Map.unmodifiable(trustedKeys);

  final Map<String, String> _trustedKeys;

  Future<void> verify({
    required Map<String, Object?> payload,
    required Object? signatureValue,
  }) async {
    if (_trustedKeys.isEmpty) {
      throw StateError('未配置 App 线路签名受信公钥');
    }
    final signature = _map(signatureValue, 'routing_signature');
    final algorithm = _string(signature, 'alg');
    final keyId = _string(signature, 'kid');
    final canonicalization = _string(signature, 'canonicalization');
    final encodedSignature = _string(signature, 'value');
    if (algorithm != 'Ed25519' || canonicalization != 'JCS-RFC8785') {
      throw const FormatException('线路签名算法或规范不受支持');
    }

    final encodedKey = _trustedKeys[keyId];
    if (encodedKey == null) {
      throw FormatException('线路签名密钥 $keyId 不受信任');
    }

    final publicKey = SimplePublicKey(
      _decodeBase64Url(encodedKey),
      type: KeyPairType.ed25519,
    );
    final valid = await Ed25519().verify(
      utf8.encode(canonicalJson(payload)),
      signature: Signature(
        _decodeBase64Url(encodedSignature),
        publicKey: publicKey,
      ),
    );
    if (!valid) throw const FormatException('线路配置签名验证失败');
  }

  static List<int> _decodeBase64Url(String value) {
    try {
      return base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw const FormatException('线路签名 Base64URL 格式无效');
    }
  }

  static Map<String, Object?> _map(Object? value, String field) {
    if (value is! Map) throw FormatException('$field 格式无效');
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  static String _string(Map<String, Object?> value, String field) {
    final item = value[field];
    if (item is! String || item.trim().isEmpty) {
      throw FormatException('routing_signature.$field 格式无效');
    }
    return item.trim();
  }
}
