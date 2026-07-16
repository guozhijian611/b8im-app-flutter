import 'dart:convert';

import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:b8im_app_flutter/src/session/app_session_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/tenant_fixture.dart';

void main() {
  test('App 登录、客户端配置和 IM challenge 使用原生端鉴权边界', () async {
    final requests = <http.Request>[];
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path == '/saimulti/app/im/login') {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        expect(body['client_family'], 'app');
        expect(body['os'], 'ios');
        expect(body['device_id'], 'device-01');
        expect(body['package_name'], 'love.idev.b8im');
        return _response({
          'organization': 1,
          'deployment_id': 'b8im-test',
          'token': {
            'access_token': _jwt({
              'iss': 'b8im-test',
              'aud': 'app-api',
              'deployment_id': 'b8im-test',
              'organization': 1,
              'device_id': 'device-01',
              'client_family': 'app',
              'os': 'ios',
              'exp': now + 600,
            }),
          },
          'user': {
            'id': 9,
            'user_id': 'user-01',
            'account': 'acceptance',
            'nickname': '验收用户',
          },
        });
      }
      if (path == '/saimulti/client/config') {
        expect(request.url.queryParameters['client_family'], 'app');
        return _response({
          'version': 1,
          'organization': 1,
          'deployment_id': 'b8im-test',
          'features': <String, Object?>{},
          'modules': <Object?>[],
          'tabbar': <Object?>[],
        });
      }
      if (path == '/saimulti/app/im/imToken') {
        expect(jsonDecode(request.body), {
          'device_id': 'device-01',
          'client_id': 'client-01',
        });
        return _response({
          'token': _jwt({
            'iss': 'b8im-test',
            'aud': 'im',
            'deployment_id': 'b8im-test',
            'organization': 1,
            'user_id': 'user-01',
            'device_id': 'device-01',
            'client_id': 'client-01',
            'client_family': 'app',
            'os': 'ios',
            'session_id': '0123456789abcdef0123456789abcdef',
            'exp': now + 60,
          }),
        });
      }
      return http.Response('not found', 404);
    });
    final api = AppApiClient(httpClient: client);
    final service = AppSessionService(api);
    final tenant = tenantFixture();
    const runtime = AppClientRuntime(os: 'ios');

    final session = await service.login(
      tenant: tenant,
      account: 'acceptance',
      password: 'secret',
      deviceId: 'device-01',
      runtime: runtime,
    );
    final config = await service.fetchClientConfig(
      tenant: tenant,
      session: session,
    );
    final challenge = await service.issueImChallenge(
      tenant: tenant,
      session: session,
      clientId: 'client-01',
    );

    expect(session.user.userId, 'user-01');
    expect(config, isA<Map>());
    expect(challenge.credentialSessionId, '0123456789abcdef0123456789abcdef');
    expect(requests, hasLength(3));
    for (final request in requests) {
      expect(request.headers['app-id'], '1');
      expect(
        request.headers['traceparent'],
        matches(RegExp(r'^00-[a-f0-9]{32}-[a-f0-9]{16}-01$')),
      );
    }
    expect(requests.first.headers['authorization'], isNull);
    expect(requests[1].headers['authorization'], startsWith('Bearer '));
    expect(requests[2].headers['authorization'], startsWith('Bearer '));
    api.close();
  });
}

http.Response _response(Object? data) => http.Response(
  jsonEncode({'code': 200, 'message': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);

String _jwt(Map<String, Object?> payload) {
  final header = base64Url
      .encode(utf8.encode(jsonEncode({'alg': 'none'})))
      .replaceAll('=', '');
  final body = base64Url
      .encode(utf8.encode(jsonEncode(payload)))
      .replaceAll('=', '');
  return '$header.$body.signature';
}
