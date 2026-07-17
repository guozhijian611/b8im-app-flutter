import 'dart:convert';

import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/qr_login/app_qr_login_service.dart';
import 'package:b8im_app_flutter/src/qr_login/web_login_qr_payload.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/tenant_fixture.dart';

const _qrId = '0123456789abcdef0123456789abcdef';
const _scanToken = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';

void main() {
  test('scan 与 confirm 使用 App API、Bearer 和 App-Id', () async {
    final requests = <http.Request>[];
    final api = AppApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        final body = jsonDecode(request.body);
        if (request.url.path == '/saimulti/app/im/qrLogin/scan') {
          expect(body, {'qr_id': _qrId, 'scan_token': _scanToken});
          expect(request.body, isNot(contains('access-token')));
          return _response({
            'qr_id': _qrId,
            'status': 'scanned',
            'organization': 1,
            'organization_name': 'b8im 测试机构',
            'web_origin': 'https://web.example.test',
            'browser_device': 'brow…ce-1',
            'expires_at': 4102444800,
          });
        }
        if (request.url.path == '/saimulti/app/im/qrLogin/confirm') {
          expect(body, {'qr_id': _qrId});
          return _response({'qr_id': _qrId, 'status': 'confirmed'});
        }
        return http.Response('not found', 404);
      }),
    );
    final service = AppQrLoginService(
      api,
      now: () => DateTime.utc(2026, 7, 17),
    );
    final tenant = tenantFixture();
    final session = _session();
    final payload = WebLoginQrPayload.parse(
      'b8im://web-login?qr_id=$_qrId&scan_token=$_scanToken'
      '&organization=1&deployment_id=b8im-test',
      tenant,
    );

    final scan = await service.scan(
      tenant: tenant,
      session: session,
      payload: payload,
    );
    await service.confirm(tenant: tenant, session: session, qrId: scan.qrId);

    expect(
      scan.expiresAt,
      DateTime.fromMillisecondsSinceEpoch(4102444800000, isUtc: true),
    );
    expect(scan.organizationName, 'b8im 测试机构');
    expect(scan.webOrigin, Uri.parse('https://web.example.test'));
    expect(scan.browserDevice, 'brow…ce-1');
    expect(requests, hasLength(2));
    for (final request in requests) {
      expect(request.method, 'POST');
      expect(request.headers['app-id'], '1');
      expect(request.headers['authorization'], 'Bearer access-token');
    }
    api.close();
  });

  test('拒绝过期或与二维码不一致的 scan 响应', () async {
    final tenant = tenantFixture();
    final payload = WebLoginQrPayload.parse(
      'b8im://web-login?qr_id=$_qrId&scan_token=$_scanToken'
      '&organization=1&deployment_id=b8im-test',
      tenant,
    );
    Future<void> expectRejected(Map<String, Object?> data) async {
      final api = AppApiClient(
        httpClient: MockClient((_) async => _response(data)),
      );
      final service = AppQrLoginService(
        api,
        now: () => DateTime.utc(2026, 7, 17),
      );
      await expectLater(
        service.scan(tenant: tenant, session: _session(), payload: payload),
        throwsFormatException,
      );
      api.close();
    }

    await expectRejected({
      'qr_id': 'abcdef0123456789abcdef0123456789',
      'status': 'scanned',
      'organization': 1,
      'organization_name': 'b8im 测试机构',
      'web_origin': 'https://web.example.test',
      'browser_device': 'brow…ce-1',
      'expires_at': 4102444800,
    });
    await expectRejected({
      'qr_id': _qrId,
      'status': 'scanned',
      'organization': 1,
      'organization_name': 'b8im 测试机构',
      'web_origin': 'https://web.example.test',
      'browser_device': 'brow…ce-1',
      'expires_at': 946684800,
    });
  });
}

AppSession _session() => const AppSession(
  accessToken: 'access-token',
  expireAt: 4102444800,
  organization: 1,
  deploymentId: 'b8im-test',
  deviceId: 'device-01',
  runtime: AppClientRuntime(os: 'ios'),
  user: AppUser(
    id: '9',
    userId: 'user-01',
    account: 'acceptance',
    nickname: '验收用户',
  ),
);

http.Response _response(Object? data) => http.Response(
  jsonEncode({'code': 200, 'message': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);
