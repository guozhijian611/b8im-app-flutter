import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../discovery/tenant_config.dart';
import '../observability/trace_context.dart';

enum AppApiMethod { get, post }

final class AppApiClient {
  AppApiClient({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  }) : _httpClient = httpClient ?? http.Client();

  final http.Client _httpClient;
  final Duration timeout;

  Future<Object?> request(
    TenantConfig tenant,
    String path, {
    AppApiMethod method = AppApiMethod.get,
    String? accessToken,
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) async {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw const FormatException('API 路径必须是站内绝对路径');
    }
    final base = tenant.routing.primary.endpoints.apiServerUri;
    final uri = base.resolve(path).replace(queryParameters: query);
    final trace = TraceContext.root();
    final headers = trace.injectHttp({
      'Accept': 'application/json',
      'App-Id': tenant.organization.toString(),
      if (accessToken != null && accessToken.trim().isNotEmpty)
        'Authorization': 'Bearer ${accessToken.trim()}',
      if (body != null) 'Content-Type': 'application/json',
    });

    late http.Response response;
    try {
      response = switch (method) {
        AppApiMethod.get =>
          await _httpClient.get(uri, headers: headers).timeout(timeout),
        AppApiMethod.post =>
          await _httpClient
              .post(
                uri,
                headers: headers,
                body: body == null ? null : jsonEncode(body),
              )
              .timeout(timeout),
      };
    } on TimeoutException {
      throw const AppApiException('请求超时，请检查目标服务');
    }

    return _responseData(response);
  }

  Future<Object?> multipart(
    TenantConfig tenant,
    String path, {
    required String accessToken,
    required String filePath,
    required String filename,
    required String mimeType,
    String fileField = 'file',
    Map<String, String> fields = const {},
  }) async {
    if (!path.startsWith('/') || path.startsWith('//')) {
      throw const FormatException('API 路径必须是站内绝对路径');
    }
    final uri = tenant.routing.primary.endpoints.apiServerUri.resolve(path);
    final trace = TraceContext.root();
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(
        trace.injectHttp({
          'Accept': 'application/json',
          'App-Id': tenant.organization.toString(),
          'Authorization': 'Bearer ${accessToken.trim()}',
        }),
      )
      ..fields.addAll(fields)
      ..files.add(
        await http.MultipartFile.fromPath(
          fileField,
          filePath,
          filename: filename,
          contentType: MediaType.parse(mimeType),
        ),
      );
    late http.Response response;
    try {
      final streamed = await _httpClient.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const AppApiException('请求超时，请检查目标服务');
    }
    return _responseData(response);
  }

  static Object? _responseData(http.Response response) {
    final payload = _decode(response.body);
    final code = payload['code'];
    if (response.statusCode != 200 || code != 200) {
      final message = payload['message'];
      throw AppApiException(
        message is String && message.trim().isNotEmpty
            ? message.trim()
            : '请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
        code: code is int ? code : null,
      );
    }
    if (!payload.containsKey('data')) {
      throw const AppApiException('API 响应缺少 data');
    }
    return payload['data'];
  }

  void close() => _httpClient.close();

  static Map<String, Object?> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException();
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      throw const AppApiException('API 响应不是有效 JSON 对象');
    }
  }
}

final class AppApiException implements Exception {
  const AppApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final int? code;

  @override
  String toString() => message;
}
