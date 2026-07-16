import 'dart:async';
import 'dart:convert';

import 'package:b8im_app_flutter/src/im/app_im_connection.dart';
import 'package:b8im_app_flutter/src/im/im_socket.dart';
import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:b8im_app_flutter/src/session/app_session_service.dart';
import 'package:b8im_app_flutter/src/storage/im_sync_cursor_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/tenant_fixture.dart';

void main() {
  test('App IM 持久在线连接完成 AUTH/SYNC 并等待 SEND_ACK', () async {
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
                'os': 'ios',
                'session_id': 'abcdef0123456789abcdef0123456789',
                'exp': now + 60,
              }),
            },
          }),
          200,
        );
      }),
    );
    final socket = _MessagingSocket();
    final cursor = _MemoryCursor('0');
    final session = AppSession(
      accessToken: 'access-token',
      expireAt: now + 600,
      organization: 1,
      deploymentId: 'b8im-test',
      deviceId: 'device-01',
      runtime: const AppClientRuntime(os: 'ios'),
      user: const AppUser(
        id: '9',
        userId: 'user-01',
        account: 'acceptance',
        nickname: '验收用户',
      ),
    );

    final connection = await AppImConnection.connect(
      tenant: tenantFixture(),
      session: session,
      sessionService: AppSessionService(api),
      cursorStore: cursor,
      socketFactory: (_) async => socket,
    );

    expect(connection.isConnected, isTrue);
    expect(connection.bootstrap.previousGlobalSeq, '0');
    expect(connection.bootstrap.nextGlobalSeq, '4');
    expect(connection.bootstrap.syncedMessages.single.messageId, 'message-04');
    expect(cursor.value, '4');
    expect(socket.closed, isFalse);

    final sent = await connection.sendText(
      conversationType: 1,
      toUserId: 'peer-01',
      text: 'Flutter message',
    );
    expect(sent.displayText, 'Flutter message');
    expect(sent.senderId, 'user-01');
    expect(socket.commands, ['auth', 'sync', 'send']);
    expect(socket.closed, isFalse);

    await connection.close();
    expect(socket.closed, isTrue);
    expect(connection.isConnected, isFalse);
    api.close();
  });
}

final class _MemoryCursor implements ImSyncCursorGateway {
  _MemoryCursor(this.value);

  String value;

  @override
  Future<String> read(int organization, String userId) async => value;

  @override
  Future<void> write(int organization, String userId, String cursor) async {
    value = cursor;
  }
}

final class _MessagingSocket implements ImSocket {
  _MessagingSocket() {
    _controller.add(
      jsonEncode({
        'cmd': 'auth',
        // WebSocket 握手阶段尚未建立租户身份，线上 challenge 固定为 0。
        'organization': 0,
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
    if (command != 'ping') commands.add(command);
    switch (command) {
      case 'auth':
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
              'os': 'ios',
            },
          }),
        );
      case 'sync':
        _controller.add(
          jsonEncode({
            'cmd': 'sync_ack',
            'organization': 1,
            'data': {
              'scope': 'global',
              'messages': [
                _message(
                  messageId: 'message-04',
                  clientMsgId: 'remote-04',
                  messageSeq: 4,
                  globalSeq: '4',
                  senderId: 'peer-01',
                  text: 'Synced',
                ),
              ],
              'next_after_global_seq': '4',
              'has_more': false,
            },
          }),
        );
      case 'send':
        final clientMsgId = packet['client_msg_id']! as String;
        final data = packet['data']! as Map<String, Object?>;
        final content = data['content']! as Map<String, Object?>;
        _controller.add(
          jsonEncode({
            'cmd': 'send_ack',
            'organization': 1,
            'client_msg_id': clientMsgId,
            'data': {
              'ok': true,
              'duplicated': false,
              'message': _message(
                messageId: 'message-05',
                clientMsgId: clientMsgId,
                messageSeq: 5,
                globalSeq: '5',
                senderId: 'user-01',
                text: content['text']! as String,
              ),
            },
          }),
        );
      case 'ping':
        _controller.add(
          jsonEncode({'cmd': 'pong', 'organization': 1, 'data': {}}),
        );
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }
}

Map<String, Object?> _message({
  required String messageId,
  required String clientMsgId,
  required int messageSeq,
  required String globalSeq,
  required String senderId,
  required String text,
}) => {
  'organization': 1,
  'global_seq': globalSeq,
  'conversation_id': 'conversation-01',
  'conversation_type': 1,
  'message_id': messageId,
  'message_seq': messageSeq,
  'client_msg_id': clientMsgId,
  'sender_id': senderId,
  'sender_user': null,
  'message_type': 1,
  'content': {'text': text},
  'status': 'normal',
  'edit_time': '',
  'edit_count': 0,
  'create_time': '2026-07-16 21:00:00',
  'update_time': '2026-07-16 21:00:00',
};

String _jwt(Map<String, Object?> payload) {
  final header = base64Url
      .encode(utf8.encode(jsonEncode({'alg': 'none'})))
      .replaceAll('=', '');
  final body = base64Url
      .encode(utf8.encode(jsonEncode(payload)))
      .replaceAll('=', '');
  return '$header.$body.signature';
}
