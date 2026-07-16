import 'dart:convert';
import 'dart:io';

import '../discovery/tenant_config.dart';

final class AppClientRuntime {
  const AppClientRuntime({
    required this.os,
    this.appMarket = 'direct',
    this.packageName = 'love.idev.b8im',
    this.channel = 'direct',
  });

  factory AppClientRuntime.current() => AppClientRuntime(
    os: Platform.isAndroid
        ? 'android'
        : Platform.isIOS
        ? 'ios'
        : 'other',
  );

  final String os;
  final String appMarket;
  final String packageName;
  final String channel;
}

final class AppUser {
  const AppUser({
    required this.id,
    required this.userId,
    required this.account,
    required this.nickname,
  });

  factory AppUser.fromJson(Object? value) {
    final map = _map(value, 'user');
    return AppUser(
      id: _stringValue(map['id'], 'user.id'),
      userId: _stringValue(map['user_id'], 'user.user_id'),
      account: _stringValue(map['account'], 'user.account'),
      nickname: _stringValue(map['nickname'], 'user.nickname'),
    );
  }

  final String id;
  final String userId;
  final String account;
  final String nickname;
}

final class AppSession {
  const AppSession({
    required this.accessToken,
    required this.expireAt,
    required this.organization,
    required this.deploymentId,
    required this.deviceId,
    required this.runtime,
    required this.user,
  });

  final String accessToken;
  final int expireAt;
  final int organization;
  final String deploymentId;
  final String deviceId;
  final AppClientRuntime runtime;
  final AppUser user;
}

final class ImChallengeCredential {
  const ImChallengeCredential({
    required this.token,
    required this.expireAt,
    required this.clientId,
    required this.credentialSessionId,
  });

  final String token;
  final int expireAt;
  final String clientId;
  final String credentialSessionId;
}

Map<String, Object?> decodeJwtPayload(String token) {
  final parts = token.split('.');
  if (parts.length != 3 || parts.any((part) => part.isEmpty)) {
    throw const FormatException('JWT 格式无效');
  }
  try {
    final bytes = base64Url.decode(base64Url.normalize(parts[1]));
    return _map(jsonDecode(utf8.decode(bytes)), 'JWT payload');
  } on Object {
    throw const FormatException('JWT payload 无效');
  }
}

void validateAccessToken({
  required String token,
  required TenantConfig tenant,
  required String deviceId,
  required AppClientRuntime runtime,
}) {
  final claims = decodeJwtPayload(token);
  final audiences = _audiences(claims['aud']);
  final expireAt = claims['exp'];
  if (claims['iss'] != tenant.deploymentId ||
      claims['deployment_id'] != tenant.deploymentId ||
      claims['organization'] != tenant.organization ||
      !audiences.contains('app-api') ||
      claims['device_id'] != deviceId ||
      claims['client_family'] != 'app' ||
      claims['os'] != runtime.os ||
      expireAt is! int ||
      expireAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
    throw const FormatException('App access token 与发现、设备或运行平台不一致');
  }
}

void validateImChallengeToken({
  required String token,
  required AppSession session,
  required String clientId,
}) {
  final claims = decodeJwtPayload(token);
  final audiences = _audiences(claims['aud']);
  final expireAt = claims['exp'];
  final credentialSessionId = claims['session_id'];
  if (claims['iss'] != session.deploymentId ||
      claims['deployment_id'] != session.deploymentId ||
      claims['organization'] != session.organization ||
      claims['user_id'] != session.user.userId ||
      claims['device_id'] != session.deviceId ||
      claims['client_id'] != clientId ||
      claims['client_family'] != 'app' ||
      claims['os'] != session.runtime.os ||
      !audiences.contains('im') ||
      expireAt is! int ||
      expireAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000 ||
      credentialSessionId is! String ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(credentialSessionId)) {
    throw const FormatException('IM challenge token 与 App 会话不一致');
  }
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map) throw FormatException('$field 格式无效');
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String _stringValue(Object? value, String field) {
  if ((value is! String && value is! num) || value.toString().trim().isEmpty) {
    throw FormatException('$field 格式无效');
  }
  return value.toString().trim();
}

Set<String> _audiences(Object? value) {
  if (value is String && value.trim().isNotEmpty) return {value.trim()};
  if (value is List &&
      value.isNotEmpty &&
      value.every((item) => item is String && item.trim().isNotEmpty)) {
    return value.cast<String>().map((item) => item.trim()).toSet();
  }
  throw const FormatException('JWT aud 声明无效');
}
