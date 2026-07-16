import '../discovery/tenant_config.dart';
import '../network/app_api_client.dart';
import 'app_session.dart';

final class AppSessionService {
  AppSessionService(this._api);

  final AppApiClient _api;

  Future<AppSession> login({
    required TenantConfig tenant,
    required String account,
    required String password,
    required String deviceId,
    required AppClientRuntime runtime,
  }) async {
    final data = _map(
      await _api.request(
        tenant,
        '/saimulti/app/im/login',
        method: AppApiMethod.post,
        body: {
          'account': account.trim(),
          'password': password,
          'device_id': deviceId,
          'client_family': 'app',
          'os': runtime.os,
          'app_market': runtime.appMarket,
          'package_name': runtime.packageName,
          'channel': runtime.channel,
        },
      ),
      'login',
    );
    if (data['organization'] != tenant.organization ||
        data['deployment_id'] != tenant.deploymentId) {
      throw const FormatException('登录响应与发现上下文不一致');
    }
    final token = _map(data['token'], 'token');
    final accessToken = _string(token, 'access_token');
    validateAccessToken(
      token: accessToken,
      tenant: tenant,
      deviceId: deviceId,
      runtime: runtime,
    );
    final claims = decodeJwtPayload(accessToken);

    return AppSession(
      accessToken: accessToken,
      expireAt: claims['exp'] as int,
      organization: tenant.organization,
      deploymentId: tenant.deploymentId,
      deviceId: deviceId,
      runtime: runtime,
      user: AppUser.fromJson(data['user']),
    );
  }

  Future<ImChallengeCredential> issueImChallenge({
    required TenantConfig tenant,
    required AppSession session,
    required String clientId,
  }) async {
    final data = _map(
      await _api.request(
        tenant,
        '/saimulti/app/im/imToken',
        method: AppApiMethod.post,
        accessToken: session.accessToken,
        body: {'device_id': session.deviceId, 'client_id': clientId},
      ),
      'imToken',
    );
    final token = _string(data, 'token');
    validateImChallengeToken(
      token: token,
      session: session,
      clientId: clientId,
    );
    final claims = decodeJwtPayload(token);

    return ImChallengeCredential(
      token: token,
      expireAt: claims['exp'] as int,
      clientId: clientId,
      credentialSessionId: claims['session_id'] as String,
    );
  }

  Future<Object?> fetchClientConfig({
    required TenantConfig tenant,
    required AppSession session,
  }) {
    return _api.request(
      tenant,
      '/saimulti/client/config',
      accessToken: session.accessToken,
      query: const {'client_family': 'app'},
    );
  }

  static Map<String, Object?> _map(Object? value, String field) {
    if (value is! Map) throw FormatException('$field 响应格式无效');
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  static String _string(Map<String, Object?> value, String field) {
    final item = value[field];
    if (item is! String || item.trim().isEmpty) {
      throw FormatException('$field 格式无效');
    }
    return item.trim();
  }
}
