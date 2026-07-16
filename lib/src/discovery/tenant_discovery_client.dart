import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../observability/trace_context.dart';
import '../security/routing_signature_verifier.dart';
import 'tenant_config.dart';

abstract interface class TenantDiscoveryGateway {
  Future<TenantConfig> discoverByEnterpriseCode(
    String enterpriseCode, {
    String? deviceId,
  });

  Future<TenantConfig> discoverByDomain(String domain, {String? deviceId});
}

final class TenantDiscoveryClient implements TenantDiscoveryGateway {
  TenantDiscoveryClient({
    required this.discoveryBaseUri,
    required this.signatureVerifier,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 8),
  }) : _httpClient = httpClient ?? http.Client();

  final Uri discoveryBaseUri;
  final RoutingSignatureVerifier signatureVerifier;
  final http.Client _httpClient;
  final Duration timeout;

  @override
  Future<TenantConfig> discoverByEnterpriseCode(
    String enterpriseCode, {
    String? deviceId,
  }) {
    final normalized = enterpriseCode.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]{1,63}$').hasMatch(normalized)) {
      throw const FormatException('企业码格式无效');
    }
    return _discover({'enterprise_code': normalized}, deviceId: deviceId);
  }

  @override
  Future<TenantConfig> discoverByDomain(String domain, {String? deviceId}) {
    final normalized = domain.trim().toLowerCase().replaceFirst(
      RegExp(r'^www\.'),
      '',
    );
    final parsed = Uri.tryParse('https://$normalized');
    if (parsed == null || parsed.host != normalized || normalized.isEmpty) {
      throw const FormatException('域名格式无效');
    }
    return _discover({
      'mode': 'domain',
      'domain': normalized,
    }, deviceId: deviceId);
  }

  Future<TenantConfig> _discover(
    Map<String, String> query, {
    String? deviceId,
  }) async {
    final uri = discoveryBaseUri
        .resolve('/saimulti/appInfo')
        .replace(queryParameters: {...query, 'client_family': 'app'});
    final trace = TraceContext.root();
    final headers = trace.injectHttp({
      'Accept': 'application/json',
      if (deviceId != null && deviceId.trim().isNotEmpty)
        'X-Device-Id': deviceId.trim(),
    });

    late http.Response response;
    try {
      response = await _httpClient.get(uri, headers: headers).timeout(timeout);
    } on TimeoutException {
      throw const TenantDiscoveryException('企业信息请求超时');
    }

    final decoded = _decodeJson(response.body);
    final code = decoded['code'];
    if (response.statusCode != 200 || code != 200) {
      final message = decoded['message'];
      throw TenantDiscoveryException(
        message is String && message.trim().isNotEmpty
            ? message.trim()
            : '企业信息请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    final data = _map(decoded['data'], 'data');
    await signatureVerifier.verify(
      payload: TenantConfig.signaturePayload(data),
      signatureValue: data['routing_signature'],
    );
    return TenantConfig.fromJson(data);
  }

  void close() => _httpClient.close();

  static Map<String, Object?> _decodeJson(String body) {
    try {
      return _map(jsonDecode(body), 'response');
    } on FormatException {
      throw const TenantDiscoveryException('企业信息响应不是有效 JSON');
    }
  }

  static Map<String, Object?> _map(Object? value, String field) {
    if (value is! Map) {
      throw TenantDiscoveryException('企业信息 $field 格式无效');
    }
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
}

final class TenantDiscoveryException implements Exception {
  const TenantDiscoveryException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
