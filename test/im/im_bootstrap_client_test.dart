import 'dart:async';
import 'dart:convert';

import 'package:b8im_app_flutter/src/im/im_bootstrap_client.dart';
import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:b8im_app_flutter/src/session/app_session_service.dart';
import 'package:b8im_app_flutter/src/storage/im_sync_cursor_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/tenant_fixture.dart';

void main() {
  test('App 通过线上协议形态完成 AUTH_ACK 与全局 SYNC_ACK', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = AppApiClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, '/saimulti/app/im/imToken');
        return http.Response(
          jsonEncode({
            'code': 200,
            'message': 'success',
            'data': {
              'token': _jwt({
                'iss': 'b8im-test',
                'aud': 'im',
                'deployment_id': 'b8im-test',
                'organization': 1,
                'user_id': 'user-01',
                'device_id': 'device-01',
                'client_id': 'client-01',
                'client_family': 'app',
                'os': 'android',
                'session_id': 'abcdef0123456789abcdef0123456789',
                'exp': now + 60,
              }),
            },
          }),
          200,
        );
      }),
    );
    final socket = _FakeImSocket();
    final cursor = _FakeCursorStore('41');
    final client = ImBootstrapClient(
      sessionService: AppSessionService(api),
      cursorStore: cursor,
      socketFactory: (_) async => socket,
    );
    final session = AppSession(
      accessToken: 'access-token',
      expireAt: now + 600,
      organization: 1,
      deploymentId: 'b8im-test',
      deviceId: 'device-01',
      runtime: const AppClientRuntime(os: 'android'),
      user: const AppUser(
        id: '9',
        userId: 'user-01',
        account: 'acceptance',
        nickname: '验收用户',
      ),
    );

    final result = await client.bootstrap(
      tenant: tenantFixture(),
      session: session,
    );

    expect(result.clientId, 'client-01');
    expect(result.connectionSessionId, 'connection-session-01');
    expect(result.previousGlobalSeq, '41');
    expect(result.nextGlobalSeq, '42');
    expect(result.syncedMessageCount, 1);
    expect(cursor.value, '42');
    expect(socket.commands, ['auth', 'sync']);
    expect(socket.closed, isTrue);
    api.close();
  });
}

final class _FakeCursorStore implements ImSyncCursorGateway {
  _FakeCursorStore(this.value);

  String value;

  @override
  Future<String> read(int organization, String userId) async => value;

  @override
  Future<void> write(int organization, String userId, String cursor) async {
    value = cursor;
  }
}

final class _FakeImSocket implements ImSocket {
  _FakeImSocket() {
    _controller.add(
      jsonEncode({
        'cmd': 'auth',
        'organization': 1,
        'data': {'client_id': 'client-01'},
      }),
    );
  }

  final StreamController<Object?> _controller = StreamController();
  final List<String> commands = [];
  bool closed = false;

  @override
  Stream<Object?> get stream => _controller.stream;

  @override
  void send(Object? value) {
    final packet = jsonDecode(value! as String) as Map<String, Object?>;
    final command = packet['cmd']! as String;
    commands.add(command);
    if (command == 'auth') {
      final data = packet['data']! as Map<String, Object?>;
      expect(data['client_family'], 'app');
      expect(data['os'], 'android');
      _controller.add(
        jsonEncode({
          'cmd': 'auth_ack',
          'organization': 1,
          'data': {
            'ok': true,
            'user_id': 'user-01',
            'device_id': 'device-01',
            'client_id': 'client-01',
            'credential_session_id': 'abcdef0123456789abcdef0123456789',
            'session_id': 'connection-session-01',
            'client_family': 'app',
            'os': 'android',
          },
        }),
      );
    } else if (command == 'sync') {
      final data = packet['data']! as Map<String, Object?>;
      expect(data['after_global_seq'], '41');
      _controller.add(
        jsonEncode({
          'cmd': 'sync_ack',
          'organization': 1,
          'data': {
            'scope': 'global',
            'messages': [
              {'global_seq': '42'},
            ],
            'next_after_global_seq': '42',
            'has_more': false,
          },
        }),
      );
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}

String _jwt(Map<String, Object?> payload) {
  final header = base64Url
      .encode(utf8.encode(jsonEncode({'alg': 'none'})))
      .replaceAll('=', '');
  final body = base64Url
      .encode(utf8.encode(jsonEncode(payload)))
      .replaceAll('=', '');
  return '$header.$body.signature';
}
