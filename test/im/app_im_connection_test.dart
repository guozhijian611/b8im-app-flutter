import 'dart:async';
import 'dart:convert';

import 'package:b8im_app_flutter/src/im/app_im_connection.dart';
import 'package:b8im_app_flutter/src/im/im_socket.dart';
import 'package:b8im_app_flutter/src/messaging/app_im_models.dart';
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
    expect(sent.deliveryStatus, AppImDeliveryStatus.sent);
    final receipt = await connection.acknowledge(
      messageId: 'message-04',
      status: AppImDeliveryStatus.read,
    );
    expect(receipt.status, AppImDeliveryStatus.read);
    final read = await connection.markConversationRead(
      conversationId: 'conversation-01',
      lastReadMessageId: 'message-04',
    );
    expect(read.lastReadSeq, 4);
    expect(
      socket.commands,
      containsAll(['auth', 'sync', 'send', 'ack', 'conversation_read']),
    );
    expect(socket.closed, isFalse);

    await connection.close();
    expect(socket.closed, isTrue);
    expect(connection.isConnected, isFalse);
    api.close();
  });

  test('App IM 断线后指数退避重连并从持久游标恢复 SYNC', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = AppApiClient(
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        final clientId = body['client_id']! as String;
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
                'client_id': clientId,
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
    final first = _MessagingSocket(clientId: 'client-01', globalSeq: 4);
    final second = _MessagingSocket(clientId: 'client-02', globalSeq: 6);
    final sockets = <_MessagingSocket>[first, second];
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
    final runtime = await AppImConnector(
      sessionService: AppSessionService(api),
      cursorStore: cursor,
      socketFactory: (_) async => sockets.removeAt(0),
      reconnectDelays: const [Duration.zero],
      sleep: (_) async {},
    ).connect(tenant: tenantFixture(), session: session);
    final statuses = <AppImConnectionStatus>[];
    final subscription = runtime.events.listen((event) {
      if (event.connectionStatus case final status?) statuses.add(status);
    });
    final recovered = runtime.events.firstWhere(
      (event) => event.command == 'sync' && event.message?.globalSeq == '6',
    );

    await first.remoteClose();
    await recovered.timeout(const Duration(seconds: 2));

    expect(runtime.isConnected, isTrue);
    expect(runtime.bootstrap.clientId, 'client-02');
    expect(runtime.bootstrap.previousGlobalSeq, '4');
    expect(runtime.bootstrap.nextGlobalSeq, '6');
    expect(cursor.value, '6');
    expect(
      statuses,
      containsAllInOrder([
        AppImConnectionStatus.reconnecting,
        AppImConnectionStatus.connected,
      ]),
    );

    await subscription.cancel();
    await runtime.close();
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
  _MessagingSocket({this.clientId = 'client-01', this.globalSeq = 4}) {
    _controller.add(
      jsonEncode({
        'cmd': 'auth',
        // WebSocket 握手阶段尚未建立租户身份，线上 challenge 固定为 0。
        'organization': 0,
        'data': {'client_id': clientId},
      }),
    );
  }

  final String clientId;
  final int globalSeq;
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
              'client_id': clientId,
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
                  messageId: 'message-${globalSeq.toString().padLeft(2, '0')}',
                  clientMsgId: 'remote-${globalSeq.toString().padLeft(2, '0')}',
                  messageSeq: globalSeq,
                  globalSeq: '$globalSeq',
                  senderId: 'peer-01',
                  text: 'Synced',
                ),
              ],
              'next_after_global_seq': '$globalSeq',
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
      case 'ack':
        final data = packet['data']! as Map<String, Object?>;
        final status = data['status']! as String;
        _controller.add(
          jsonEncode({
            'cmd': 'ack_ack',
            'organization': 1,
            'client_msg_id': packet['client_msg_id'],
            'data': {
              'message_id': data['message_id'],
              'conversation_id': 'conversation-01',
              'message_seq': 4,
              'sender_id': 'peer-01',
              'user_id': 'user-01',
              'status': status,
              'time': '2026-07-16 21:00:01',
            },
          }),
        );
      case 'conversation_read':
        final data = packet['data']! as Map<String, Object?>;
        _controller.add(
          jsonEncode({
            'cmd': 'conversation_read_ack',
            'organization': 1,
            'client_msg_id': packet['client_msg_id'],
            'data': {
              'conversation_id': data['conversation_id'],
              'last_read_message_id': data['last_read_message_id'],
              'last_read_seq': 4,
              'unread_count': 0,
              'user_id': 'user-01',
              'time': '2026-07-16 21:00:01',
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
    if (!_controller.isClosed) await _controller.close();
  }

  Future<void> remoteClose() => close();
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
