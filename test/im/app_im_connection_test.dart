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
    expect(connection.bootstrap.crossOrgAccessSnapshotId, '1');
    expect(connection.bootstrap.syncedMessages.single.messageId, 'message-04');
    expect(cursor.accessHighWater, '1');
    expect(cursor.value, '0');
    await connection.consumeGlobalSync(
      nextGlobalSeq: connection.bootstrap.nextGlobalSeq,
      consumer: (messages) async {
        expect(messages.single.messageId, 'message-04');
      },
    );
    expect(cursor.value, '4');
    expect(socket.closed, isFalse);

    final sent = await connection.sendText(
      conversationType: 1,
      toOrganization: 1,
      toUserId: 'peer-01',
      text: 'Flutter message',
    );
    expect(sent.displayText, 'Flutter message');
    expect(sent.senderId, 'user-01');
    expect(sent.deliveryStatus, AppImDeliveryStatus.sent);
    final asset = await connection.sendAsset(
      conversationType: 1,
      toOrganization: 1,
      toUserId: 'peer-01',
      messageType: 2,
      fileId: _assetFileId,
    );
    expect(asset.messageType, 2);
    expect(asset.assetFileId, _assetFileId);
    expect(asset.assetName, 'photo.png');
    final editResult = await connection.editMessage(
      sent,
      'Flutter edited',
      identity: _sameOrgIdentity,
    );
    expect(editResult.message!.displayText, 'Flutter edited');
    expect(editResult.changeSeq, greaterThan(0));
    await connection.recallMessage(
      editResult.message!,
      identity: _sameOrgIdentity,
    );
    await connection.deleteMessage(
      connection.bootstrap.syncedMessages.single,
      scope: 'self',
      identity: _sameOrgIdentity,
    );
    expect(await connection.sendScreenshot(_sameOrgIdentity), isNull);
    connection.sendTyping(_sameOrgIdentity);
    final receipt = await connection.acknowledge(
      message: connection.bootstrap.syncedMessages.single,
      status: AppImDeliveryStatus.read,
      identity: _sameOrgIdentity,
    );
    expect(receipt.status, AppImDeliveryStatus.read);
    final read = await connection.markConversationRead(
      identity: _sameOrgIdentity,
      lastReadMessage: connection.bootstrap.syncedMessages.single,
    );
    expect(read.lastReadSeq, 4);
    expect(
      socket.commands,
      containsAll([
        'auth',
        'sync',
        'send',
        'ack',
        'conversation_read',
        'edit',
        'recall',
        'delete',
        'screenshot',
        'typing',
      ]),
    );
    expect(socket.closed, isFalse);

    await connection.close();
    expect(socket.closed, isTrue);
    expect(connection.isConnected, isFalse);
    api.close();
  });

  test('SYNC 消费失败不提交 cursor，成功消费后才单调提交', () async {
    final cursor = _MemoryCursor('0');
    final harness = await _connectSocket(_MessagingSocket(), cursor: cursor);

    expect(cursor.value, '0');
    await expectLater(
      harness.connection.consumeGlobalSync(
        nextGlobalSeq: '4',
        consumer: (_) => Future<void>.error(StateError('consumer failed')),
      ),
      throwsA(isA<StateError>()),
    );
    expect(cursor.value, '0');
    expect(cursor.writes, isEmpty);

    await harness.connection.consumeGlobalSync(
      nextGlobalSeq: '4',
      consumer: (messages) async => expect(messages, hasLength(1)),
    );
    expect(cursor.value, '4');
    await expectLater(
      cursor.write(1, 'user-01', '3'),
      throwsA(isA<StateError>()),
    );
    expect(cursor.value, '4');

    await harness.connection.close();
    harness.api.close();
  });

  test('consumer 成功后连接关闭会使等待中的 high-water/cursor 提交失效', () async {
    final cursor = _MemoryCursor('0', blockAccessWriteCall: 2);
    final harness = await _connectSocket(
      _MessagingSocket(authAccessSnapshotId: '100', accessSnapshotId: '101'),
      cursor: cursor,
    );
    final consume = harness.connection.consumeGlobalSync(
      nextGlobalSeq: harness.connection.bootstrap.nextGlobalSeq,
      consumer: (_) async {},
    );

    await cursor.accessWriteEntered.future.timeout(const Duration(seconds: 2));
    await harness.connection.close();
    cursor.releaseAccessWrite.complete();

    expect(await consume, isFalse);
    expect(cursor.accessHighWater, '100');
    expect(cursor.value, '0');
    expect(cursor.writes, isEmpty);
    harness.api.close();
  });

  test('cursor 写入前 access epoch 变化会使旧 global SYNC task 失效', () async {
    final cursor = _MemoryCursor('0', blockCursorWriteCall: 1);
    final socket = _MessagingSocket(
      authAccessSnapshotId: '100',
      accessSnapshotId: '100',
    );
    final harness = await _connectSocket(socket, cursor: cursor);
    final consume = harness.connection.consumeGlobalSync(
      nextGlobalSeq: harness.connection.bootstrap.nextGlobalSeq,
      consumer: (_) async {},
    );
    await cursor.cursorWriteEntered.future.timeout(const Duration(seconds: 2));
    final accessApplied = harness.connection.events.firstWhere(
      (event) => event.accessChanged?.snapshotId == '101',
    );
    socket.pushRaw({
      'cmd': 'conversation.access_changed',
      'organization': 1,
      'data': {
        'event_id':
            '4747474747474747474747474747474747474747474747474747474747474747',
        'event_type': 'conversation.access_changed',
        'conversation_id': 'single-cross-01',
        'conversation_type': 1,
        'cross_org_access_snapshot_id': '101',
        'allowed': false,
        'target_organization': 1,
        'target_user_id': 'user-01',
        'peer_organization': 2,
        'peer_user_id': 'peer-01',
      },
    });
    await accessApplied.timeout(const Duration(seconds: 2));
    cursor.releaseCursorWrite.complete();

    expect(await consume, isFalse);
    expect(cursor.value, '0');
    expect(cursor.writes, isEmpty);
    expect(cursor.accessHighWater, '101');

    await harness.connection.close();
    harness.api.close();
  });

  test('持久化访问高水位使进程重启后的 100→99 保持 fail-closed', () async {
    final cursor = _MemoryCursor('0', accessHighWater: '100');
    await cursor.writeAccessSnapshotHighWater(1, 'user-01', '0');
    expect(cursor.accessHighWater, '100');
    final harness = await _connectSocket(
      _MessagingSocket(authAccessSnapshotId: '99', accessSnapshotId: '99'),
      cursor: cursor,
    );

    expect(harness.connection.isConnected, isTrue);
    expect(harness.connection.bootstrap.crossOrgAccessSnapshotId, '0');
    expect(harness.connection.bootstrap.highestCrossOrgAccessSnapshotId, '100');
    final recovered = harness.connection.events.firstWhere(
      (event) => event.accessChanged?.snapshotId == '101',
    );
    final socket = harness.connection.socket as _MessagingSocket;
    socket.pushRaw({
      'cmd': 'conversation.access_changed',
      'organization': 1,
      'data': {
        'event_id':
            '4545454545454545454545454545454545454545454545454545454545454545',
        'event_type': 'conversation.access_changed',
        'conversation_id': 'single-cross-01',
        'conversation_type': 1,
        'cross_org_access_snapshot_id': '100',
        'allowed': true,
        'target_organization': 1,
        'target_user_id': 'user-01',
        'peer_organization': 2,
        'peer_user_id': 'peer-01',
      },
    });
    socket.pushRaw({
      'cmd': 'conversation.access_changed',
      'organization': 1,
      'data': {
        'event_id':
            '4646464646464646464646464646464646464646464646464646464646464646',
        'event_type': 'conversation.access_changed',
        'conversation_id': 'single-cross-01',
        'conversation_type': 1,
        'cross_org_access_snapshot_id': '101',
        'allowed': true,
        'target_organization': 1,
        'target_user_id': 'user-01',
        'peer_organization': 2,
        'peer_user_id': 'peer-01',
      },
    });
    await recovered.timeout(const Duration(seconds: 2));
    expect(cursor.accessHighWater, '101');
    expect(
      harness.connection.recentAccessChanges.map((event) => event.snapshotId),
      ['101'],
    );

    await harness.connection.close();
    harness.api.close();
  });

  test('App IM 低快照重连保持同机构在线并在更高快照后恢复跨机构', () async {
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
    final first = _MessagingSocket(
      clientId: 'client-01',
      globalSeq: 4,
      authAccessSnapshotId: '100',
      accessSnapshotId: '100',
      syncSenderId: 'user-01',
    );
    final second = _MessagingSocket(
      clientId: 'client-02',
      globalSeq: 6,
      authAccessSnapshotId: '99',
      accessSnapshotId: '99',
      syncSenderId: 'user-01',
    );
    final third = _MessagingSocket(
      clientId: 'client-03',
      globalSeq: 8,
      authAccessSnapshotId: '101',
      accessSnapshotId: '101',
      syncSenderId: 'user-01',
    );
    final sockets = <_MessagingSocket>[first, second, third];
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
    const reconnectCrossIdentity = AppImConversationIdentityContext(
      organization: 1,
      userId: 'user-01',
      conversationId: 'conversation-01',
      conversationType: 1,
      peerOrganization: 2,
      peerUserId: 'peer-01',
    );
    runtime.registerConversationIdentities([reconnectCrossIdentity]);
    await runtime.consumeGlobalSync(
      nextGlobalSeq: runtime.bootstrap.nextGlobalSeq,
      consumer: (_) async {},
    );
    final statuses = <AppImConnectionStatus>[];
    final receivedMessageIds = <String>[];
    final degraded = Completer<void>();
    final recovered = Completer<void>();
    final subscription = runtime.events.listen((event) {
      if (event.message case final message?) {
        receivedMessageIds.add(message.messageId);
      }
      if (event.connectionStatus case final status?) {
        statuses.add(status);
        if (status == AppImConnectionStatus.connected) {
          if (runtime.bootstrap.clientId == 'client-02' &&
              !degraded.isCompleted) {
            degraded.complete();
          } else {
            unawaited(
              Future<void>.microtask(() async {
                await runtime.consumeGlobalSync(
                  nextGlobalSeq: runtime.bootstrap.nextGlobalSeq,
                  consumer: (_) async {},
                );
              }),
            );
          }
        }
      }
      if (event.command == 'sync' &&
          event.message?.globalSeq == '8' &&
          !recovered.isCompleted) {
        recovered.complete();
      }
    }, onError: (Object _) {});

    await first.remoteClose();
    await degraded.future.timeout(const Duration(seconds: 2));
    expect(runtime.isConnected, isTrue);
    expect(runtime.bootstrap.clientId, 'client-02');
    expect(runtime.bootstrap.crossOrgAccessSnapshotId, '0');
    expect(runtime.bootstrap.highestCrossOrgAccessSnapshotId, '100');
    expect(
      await runtime.consumeGlobalSync(
        nextGlobalSeq: runtime.bootstrap.nextGlobalSeq,
        consumer: (_) async {},
      ),
      isFalse,
    );
    expect(cursor.value, '4');
    expect(
      () => runtime.registerConversationIdentities([_sameOrgIdentity]),
      throwsFormatException,
    );
    second.pushRaw({
      'cmd': 'push',
      'organization': 1,
      'data': {
        'event_id':
            '6666666666666666666666666666666666666666666666666666666666666666',
        'event_type': 'message.created',
        'message_id': 'reconnect-cross-own-push',
        'conversation_id': 'conversation-01',
        'message_seq': 7,
        'message': _message(
          messageId: 'reconnect-cross-own-push',
          clientMsgId: 'reconnect-cross-own-client',
          messageSeq: 7,
          globalSeq: '7',
          senderId: 'user-01',
          text: 'must remain blocked after reconnect',
        ),
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(receivedMessageIds, isNot(contains('reconnect-cross-own-push')));

    await second.remoteClose();
    await recovered.future.timeout(const Duration(seconds: 2));
    await runtime.consumeGlobalSync(
      nextGlobalSeq: runtime.bootstrap.nextGlobalSeq,
      consumer: (_) async {},
    );

    expect(runtime.isConnected, isTrue);
    expect(runtime.bootstrap.clientId, 'client-03');
    expect(runtime.bootstrap.previousGlobalSeq, '4');
    expect(runtime.bootstrap.nextGlobalSeq, '8');
    expect(runtime.bootstrap.crossOrgAccessSnapshotId, '101');
    expect(runtime.bootstrap.highestCrossOrgAccessSnapshotId, '101');
    expect(cursor.value, '8');
    expect(receivedMessageIds, contains('message-08'));
    expect(receivedMessageIds, isNot(contains('message-06')));
    expect(second.commands, containsAllInOrder(['auth', 'sync']));
    expect(third.commands, containsAllInOrder(['auth', 'sync']));
    expect(sockets, isEmpty);
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

  test('revoke10 后断线错过 allow，reconnect11 为新页面淘汰旧 revoke 并保留同快照事件', () async {
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
    final first = _MessagingSocket(
      clientId: 'client-10',
      globalSeq: 4,
      accessSnapshotId: '10',
    );
    final second = _MessagingSocket(
      clientId: 'client-11',
      globalSeq: 6,
      accessSnapshotId: '11',
      accessChangesOnFirstGlobalSync: const [
        (
          eventId:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          snapshotId: '11',
          conversationId: 'single-cross-11-a',
          allowed: false,
          peerOrganization: 3,
          peerUserId: 'peer-11-a',
        ),
        (
          eventId:
              'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          snapshotId: '11',
          conversationId: 'single-cross-11-b',
          allowed: false,
          peerOrganization: 4,
          peerUserId: 'peer-11-b',
        ),
      ],
    );
    final sockets = <_MessagingSocket>[first, second];
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
      cursorStore: _MemoryCursor('0'),
      socketFactory: (_) async => sockets.removeAt(0),
      reconnectDelays: const [Duration.zero],
      sleep: (_) async {},
    ).connect(tenant: tenantFixture(), session: session);
    const staleRevokeId =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final revokeSeen = runtime.events.firstWhere(
      (event) => event.eventId == staleRevokeId,
    );
    first.pushRaw({
      'cmd': 'conversation.access_changed',
      'organization': 1,
      'data': {
        'event_id': staleRevokeId,
        'event_type': 'conversation.access_changed',
        'conversation_id': 'single-cross-recovered',
        'conversation_type': 1,
        'cross_org_access_snapshot_id': '10',
        'allowed': false,
        'target_organization': 1,
        'target_user_id': 'user-01',
        'peer_organization': 2,
        'peer_user_id': 'recovered-peer',
      },
    });
    await revokeSeen.timeout(const Duration(seconds: 2));
    expect(runtime.recentAccessChanges.single.eventId, staleRevokeId);

    final reconnected = runtime.events.firstWhere(
      (event) => event.connectionStatus == AppImConnectionStatus.connected,
    );
    await first.remoteClose();
    await reconnected.timeout(const Duration(seconds: 2));

    expect(runtime.bootstrap.crossOrgAccessSnapshotId, '11');
    expect(runtime.recentAccessChanges.map((event) => event.eventId), [
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    ]);
    expect(
      runtime.recentAccessChanges.every((event) => event.snapshotId == '11'),
      isTrue,
    );
    expect(
      runtime.recentAccessChanges.any(
        (event) =>
            event.eventId == staleRevokeId ||
            event.peerUserId == 'recovered-peer',
      ),
      isFalse,
    );
    expect(sockets, isEmpty);

    await Future<void>.delayed(Duration.zero);
    await runtime.close();
    api.close();
  });

  test('跨机构同名用户 PUSH 使用接收方 home 且连接层不盲发 delivered ACK', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final api = AppApiClient(
      httpClient: MockClient(
        (_) async => http.Response(
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
        ),
      ),
    );
    final socket = _MessagingSocket();
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
      cursorStore: _MemoryCursor('0'),
      socketFactory: (_) async => socket,
    );
    final pushed = connection.events.firstWhere(
      (event) => event.command == 'push',
    );

    socket.pushCrossOrganizationSameId();
    final event = await pushed.timeout(const Duration(seconds: 2));

    expect(event.message?.organization, 1);
    expect(event.message?.senderOrganization, 2);
    expect(event.message?.senderId, 'user-01');
    expect(event.message?.senderUser?.displayName, '外部同名用户 · 外部公司');
    await Future<void>.delayed(Duration.zero);
    expect(socket.commands, isNot(contains('ack')));

    await connection.close();
    api.close();
  });

  test('ACK_ACK 必须绑定原消息会话、序号和发送者复合身份', () async {
    final socket = _MessagingSocket(
      syncSenderId: 'user-01',
      ackConversationOverride: 'conversation-forged',
      ackSequenceOverride: 999,
      ackSenderOrganizationOverride: 9,
      ackSenderIdOverride: 'peer-01',
      ackOverrideMessageId: 'message-04',
    );
    final harness = await _connectSocket(socket);
    await expectLater(
      harness.connection.acknowledge(
        message: harness.connection.bootstrap.syncedMessages.single,
        status: AppImDeliveryStatus.delivered,
        identity: _sameOrgIdentity,
      ),
      throwsA(
        isA<AppImConnectionException>().having(
          (item) => item.message,
          'message',
          contains('ACK_ACK'),
        ),
      ),
    );
    await harness.connection.close();
    harness.api.close();
  });

  test('CONVERSATION_READ_ACK 必须回显最后消息 ID、序号和当前复合身份', () async {
    final socket = _MessagingSocket(
      readMessageIdOverride: 'message-forged',
      readSequenceOverride: 3,
    );
    final harness = await _connectSocket(socket);
    final last = harness.connection.bootstrap.syncedMessages.single;

    await expectLater(
      harness.connection.markConversationRead(
        identity: _sameOrgIdentity,
        lastReadMessage: last,
      ),
      throwsA(
        isA<AppImConnectionException>().having(
          (item) => item.message,
          'message',
          contains('CONVERSATION_READ_ACK'),
        ),
      ),
    );

    await harness.connection.close();
    harness.api.close();
  });

  test('认证后缺少 organization 的业务包失败关闭', () async {
    final socket = _MessagingSocket();
    final harness = await _connectSocket(socket);
    final error = harness.connection.events.firstWhere(
      (_) => false,
      orElse: () => throw StateError('连接在无 organization 业务包后未失败关闭'),
    );

    socket.pushRaw({
      'cmd': 'ack',
      'data': {
        'event_id':
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        'event_type': 'message.receipt',
      },
    });

    await expectLater(error, throwsA(isA<FormatException>()));
    await Future<void>.delayed(Duration.zero);
    expect(harness.connection.isConnected, isFalse);
    harness.api.close();
  });

  test('认证后错 home organization 的 read 包失败关闭', () async {
    final socket = _MessagingSocket();
    final harness = await _connectSocket(socket);
    final error = harness.connection.events.firstWhere(
      (_) => false,
      orElse: () => throw StateError('连接在跨 home read 包后未失败关闭'),
    );

    socket.pushRaw({
      'cmd': 'conversation_read',
      'organization': 2,
      'data': {
        'event_id':
            'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        'event_type': 'conversation.read',
      },
    });

    await expectLater(error, throwsA(isA<FormatException>()));
    await Future<void>.delayed(Duration.zero);
    expect(harness.connection.isConnected, isFalse);
    harness.api.close();
  });

  test('durable mutation 与 typing 解析保留 actor 复合身份', () async {
    final socket = _MessagingSocket();
    final harness = await _connectSocket(socket);
    final mutationFuture = harness.connection.events.firstWhere(
      (event) => event.mutation != null,
    );
    final typingFuture = harness.connection.events.firstWhere(
      (event) => event.typing != null,
    );
    socket.pushRaw({
      'cmd': 'recall',
      'organization': 1,
      'data': {
        'event_id':
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        'event_type': 'message.recalled',
        'conversation_id': 'conversation-01',
        'message_id': 'message-04',
        'message_seq': 4,
        'change_seq': 1,
        'actor_organization': 1,
        'actor_user_id': 'peer-01',
        'target_organization': null,
        'target_user_id': null,
        'status': 'recalled',
      },
    });
    socket.pushRaw({
      'cmd': 'typing',
      'organization': 1,
      'data': {
        'conversation_id': 'conversation-01',
        'actor_organization': 2,
        'actor_user_id': 'peer-01',
        'username': '外部同名用户',
      },
    });

    final mutation = (await mutationFuture).mutation!;
    final typing = (await typingFuture).typing!;
    expect(mutation.actorOrganization, 1);
    expect(mutation.actorUserId, 'peer-01');
    expect(typing.actorOrganization, 2);
    expect(typing.actorUserId, 'peer-01');

    await harness.connection.close();
    harness.api.close();
  });

  test('edit 事件拒绝同 ID 跨机构伪造 actor', () {
    final forged = _message(
      messageId: 'message-04',
      clientMsgId: 'remote-04',
      messageSeq: 4,
      globalSeq: '4',
      senderId: 'peer-01',
      text: '伪造编辑',
    );
    expect(
      () => AppImMessageMutation.fromJson('edit', {
        'event_id':
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
        'event_type': 'message.edited',
        'conversation_id': 'conversation-01',
        'message_id': 'message-04',
        'message_seq': 4,
        'change_seq': 1,
        'actor_organization': 2,
        'actor_user_id': 'peer-01',
        'target_organization': null,
        'target_user_id': null,
        'content': {'text': '伪造编辑'},
        'edit_time': '2026-07-20 12:00:00',
        'edit_count': 1,
        'message': forged,
      }, 1),
      throwsFormatException,
    );
  });

  test('AUTH_ACK 拒绝非 canonical decimal 的访问快照', () async {
    await expectLater(
      _connectSocket(_MessagingSocket(accessSnapshotId: '01')),
      throwsA(
        isA<AppImConnectionException>().having(
          (item) => item.message,
          'message',
          contains('cross_org_access_snapshot_id'),
        ),
      ),
    );
  });

  test('并发截屏请求复用同一 pending client_msg_id 且只发一次', () async {
    final socket = _MessagingSocket(deferScreenshotAck: true);
    final harness = await _connectSocket(socket);

    final first = harness.connection.sendScreenshot(_sameOrgIdentity);
    final second = harness.connection.sendScreenshot(_sameOrgIdentity);
    expect(identical(first, second), isTrue);
    expect(socket.screenshotRequestCount, 1);

    socket.completeScreenshot();
    expect(await first, isNull);
    expect(await second, isNull);

    await harness.connection.close();
    harness.api.close();
  });

  test('控制 ACK 必须绑定当前 actor 复合身份', () async {
    final socket = _MessagingSocket(
      syncSenderId: 'user-01',
      operationActorOrganizationOverride: 2,
    );
    final harness = await _connectSocket(socket);
    final own = harness.connection.bootstrap.syncedMessages.single;

    await expectLater(
      harness.connection.editMessage(
        own,
        'forged actor ack',
        identity: _sameOrgIdentity,
      ),
      throwsA(
        isA<AppImConnectionException>().having(
          (item) => item.message,
          'message',
          contains('EDIT_ACK'),
        ),
      ),
    );
    await expectLater(
      harness.connection.sendScreenshot(_sameOrgIdentity),
      throwsA(
        isA<AppImConnectionException>().having(
          (item) => item.message,
          'message',
          contains('SCREENSHOT_ACK'),
        ),
      ),
    );

    await harness.connection.close();
    harness.api.close();
  });

  test('全局 SYNC 拒绝消息 global_seq 超过 ACK next 游标', () async {
    await expectLater(
      _connectSocket(
        _MessagingSocket(globalSeq: 1, syncMessageGlobalSeqOverride: '2'),
      ),
      throwsA(
        isA<AppImConnectionException>().having(
          (error) => error.message,
          'message',
          contains('global_seq'),
        ),
      ),
    );
  });

  test('全局 SYNC 拒绝消息 global_seq 未超过请求 cursor', () async {
    await expectLater(
      _connectSocket(
        _MessagingSocket(globalSeq: 2, syncMessageGlobalSeqOverride: '1'),
        cursor: _MemoryCursor('1'),
      ),
      throwsA(
        isA<AppImConnectionException>().having(
          (error) => error.message,
          'message',
          contains('global_seq'),
        ),
      ),
    );
  });

  test('全局 SYNC 严格忽略不匹配的顶层 client_msg_id ACK', () async {
    final harness = await _connectSocket(
      _MessagingSocket(emitWrongGlobalSyncClientIdFirst: true),
    );

    expect(harness.connection.bootstrap.nextGlobalSeq, '4');

    await harness.connection.close();
    harness.api.close();
  });

  test('SCREENSHOT_ACK enabled 与 notice_message 必须一致', () async {
    final harness = await _connectSocket(
      _MessagingSocket(screenshotEnabled: true),
    );
    await expectLater(
      harness.connection.sendScreenshot(_sameOrgIdentity),
      throwsA(
        isA<AppImConnectionException>().having(
          (error) => error.message,
          'message',
          contains('SCREENSHOT_ACK'),
        ),
      ),
    );
    await harness.connection.close();
    harness.api.close();
  });

  test('conversation.access_changed 严格解析当前 target 与跨机构 peer', () async {
    final socket = _MessagingSocket();
    final harness = await _connectSocket(socket);
    final eventFuture = harness.connection.events.firstWhere(
      (event) => event.accessChanged != null,
    );
    socket.pushRaw({
      'cmd': 'conversation.access_changed',
      'organization': 1,
      'data': {
        'event_id':
            'abababababababababababababababababababababababababababababababab',
        'event_type': 'conversation.access_changed',
        'conversation_id': 'single-cross-01',
        'conversation_type': 1,
        'cross_org_access_snapshot_id': '2',
        'allowed': false,
        'target_organization': 1,
        'target_user_id': 'user-01',
        'peer_organization': 2,
        'peer_user_id': 'peer-01',
      },
    });

    final access = (await eventFuture).accessChanged!;
    expect(access.snapshotId, '2');
    expect(access.allowed, isFalse);
    expect(access.peerOrganization, 2);

    await harness.connection.close();
    harness.api.close();
  });

  test('全局 SYNC 快照跨页变化时整批丢弃且只提交稳定批次 cursor', () async {
    final cursor = _MemoryCursor('0');
    final socket = _MessagingSocket(
      syncPages: const [
        (globalSeq: 1, hasMore: true, snapshotId: '1'),
        (globalSeq: 2, hasMore: false, snapshotId: '2'),
        (globalSeq: 1, hasMore: true, snapshotId: '2'),
        (globalSeq: 2, hasMore: false, snapshotId: '2'),
      ],
    );
    final harness = await _connectSocket(socket, cursor: cursor);
    await harness.connection.consumeGlobalSync(
      nextGlobalSeq: harness.connection.bootstrap.nextGlobalSeq,
      consumer: (_) async {},
    );

    expect(harness.connection.bootstrap.nextGlobalSeq, '2');
    expect(harness.connection.bootstrap.crossOrgAccessSnapshotId, '2');
    expect(cursor.writes, ['2']);
    expect(socket.globalSyncRequestCount, 4);
    expect(socket.syncRequestIds.toSet().length, 4);

    await harness.connection.close();
    harness.api.close();
  });

  test('AUTH 高水位遇到更旧 SYNC 时同机构保持在线且跨机构 fail-closed', () async {
    final cursor = _MemoryCursor('0');
    final socket = _MessagingSocket(
      authAccessSnapshotId: '100',
      syncSenderOrganization: 2,
      syncPages: const [(globalSeq: 1, hasMore: false, snapshotId: '99')],
    );
    final harness = await _connectSocket(socket, cursor: cursor);

    expect(harness.connection.isConnected, isTrue);
    expect(harness.connection.bootstrap.crossOrgAccessSnapshotId, '0');
    expect(harness.connection.bootstrap.highestCrossOrgAccessSnapshotId, '100');
    expect(harness.connection.bootstrap.syncedMessages, isEmpty);
    final crossMessage = AppImMessage.fromRealtime(
      _message(
        messageId: 'cross-message-01',
        clientMsgId: 'cross-client-01',
        messageSeq: 1,
        globalSeq: '1',
        conversationId: 'conversation-cross-01',
        senderOrganization: 2,
        senderId: 'peer-01',
        text: 'cross',
      ),
    );
    final commandsBeforeBlockedOperations = socket.commands.length;
    Matcher accessFailure() => isA<AppImConnectionException>().having(
      (error) => error.code,
      'code',
      'IM_ACCESS_SNAPSHOT_UNSTABLE',
    );
    await expectLater(
      harness.connection.sendText(
        conversationType: 1,
        toOrganization: 2,
        toUserId: 'peer-01',
        text: 'blocked while fail-closed',
      ),
      throwsA(accessFailure()),
    );
    await expectLater(
      harness.connection.acknowledge(
        message: crossMessage,
        status: AppImDeliveryStatus.read,
        identity: _crossOrgIdentity,
      ),
      throwsA(accessFailure()),
    );
    await expectLater(
      harness.connection.markConversationRead(
        identity: _crossOrgIdentity,
        lastReadMessage: crossMessage,
      ),
      throwsA(accessFailure()),
    );
    await expectLater(
      harness.connection.syncConversation(
        identity: _crossOrgIdentity,
        afterMessageSeq: 0,
        afterChangeSeq: 0,
      ),
      throwsA(accessFailure()),
    );
    await expectLater(
      harness.connection.recallMessage(
        crossMessage,
        identity: _crossOrgIdentity,
      ),
      throwsA(accessFailure()),
    );
    await expectLater(
      harness.connection.editMessage(
        crossMessage,
        'blocked',
        identity: _crossOrgIdentity,
      ),
      throwsA(accessFailure()),
    );
    await expectLater(
      harness.connection.deleteMessage(
        crossMessage,
        scope: 'self',
        identity: _crossOrgIdentity,
      ),
      throwsA(accessFailure()),
    );
    expect(
      () => harness.connection.sendScreenshot(_crossOrgIdentity),
      throwsA(accessFailure()),
    );
    expect(
      () => harness.connection.sendTyping(_crossOrgIdentity),
      throwsA(accessFailure()),
    );
    expect(socket.commands, hasLength(commandsBeforeBlockedOperations));
    await harness.connection.sendText(
      conversationType: 1,
      toOrganization: 1,
      toUserId: 'peer-01',
      text: 'same-organization remains available',
    );
    harness.connection.sendTyping(_sameOrgIdentity);
    expect(socket.commands, contains('send'));
    expect(socket.commands, contains('typing'));
    expect(cursor.writes, isEmpty);
    harness.connection.registerConversationIdentities([_sameOrgIdentity]);
    expect(
      await harness.connection.consumeGlobalSync(
        nextGlobalSeq: '1',
        consumer: (_) async {},
      ),
      isFalse,
    );
    expect(cursor.writes, isEmpty);

    await harness.connection.close();
    harness.api.close();
  });

  test('fail-closed 冷启动未知单聊不消费当前发送者事件且不推进 global cursor', () async {
    final cursor = _MemoryCursor('0', accessHighWater: '100');
    final socket = _MessagingSocket(
      authAccessSnapshotId: '99',
      accessSnapshotId: '99',
      syncSenderId: 'user-01',
    );
    final harness = await _connectSocket(socket, cursor: cursor);
    final received = <AppImEvent>[];
    final subscription = harness.connection.events.listen(received.add);
    var consumerCalled = false;

    expect(harness.connection.bootstrap.syncedMessages, isEmpty);
    expect(
      await harness.connection.consumeGlobalSync(
        nextGlobalSeq: harness.connection.bootstrap.nextGlobalSeq,
        consumer: (_) async => consumerCalled = true,
      ),
      isFalse,
    );
    expect(consumerCalled, isFalse);
    expect(cursor.value, '0');
    expect(cursor.writes, isEmpty);

    socket.pushRaw({
      'cmd': 'push',
      'organization': 1,
      'data': {
        'event_id':
            '6161616161616161616161616161616161616161616161616161616161616161',
        'event_type': 'message.created',
        'message_id': 'unknown-own-message-01',
        'conversation_id': 'conversation-01',
        'message_seq': 2,
        'message': _message(
          messageId: 'unknown-own-message-01',
          clientMsgId: 'unknown-own-client-01',
          messageSeq: 2,
          globalSeq: '2',
          senderId: 'user-01',
          text: 'outbound cross while identity unknown',
        ),
      },
    });
    socket.pushRaw({
      'cmd': 'conversation_read',
      'organization': 1,
      'data': {
        'event_id':
            '6262626262626262626262626262626262626262626262626262626262626262',
        'event_type': 'conversation.read',
        'conversation_id': 'conversation-01',
        'last_read_message_id': 'unknown-own-message-01',
        'last_read_seq': 2,
        'unread_count': 0,
        'user_organization': 1,
        'user_id': 'user-01',
        'time': '2026-07-20 12:00:00',
      },
    });
    socket.pushRaw({
      'cmd': 'recall',
      'organization': 1,
      'data': {
        'event_id':
            '6363636363636363636363636363636363636363636363636363636363636363',
        'event_type': 'message.recalled',
        'conversation_id': 'conversation-01',
        'message_id': 'unknown-own-message-01',
        'message_seq': 2,
        'change_seq': 1,
        'actor_organization': 1,
        'actor_user_id': 'user-01',
        'target_organization': null,
        'target_user_id': null,
        'status': 'recalled',
      },
    });
    socket.pushRaw({
      'cmd': 'typing',
      'organization': 1,
      'data': {
        'conversation_id': 'conversation-01',
        'actor_organization': 1,
        'actor_user_id': 'user-01',
        'username': '当前用户',
      },
    });
    socket.pushRaw({
      'cmd': 'push',
      'organization': 1,
      'data': {
        'event_id':
            '6464646464646464646464646464646464646464646464646464646464646464',
        'event_type': 'message.created',
        'message_id': 'unknown-screenshot-01',
        'conversation_id': 'conversation-01',
        'message_seq': 3,
        'message': {
          ..._message(
            messageId: 'unknown-screenshot-01',
            clientMsgId: 'unknown-screenshot-client-01',
            messageSeq: 3,
            globalSeq: '3',
            senderId: 'system',
            text: '截屏提示',
          ),
          'message_type': 5,
          'content': {
            'text': '截屏提示',
            'actor_organization': 1,
            'actor_user_id': 'user-01',
          },
        },
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    expect(harness.connection.isConnected, isTrue);

    const crossIdentityForPending = AppImConversationIdentityContext(
      organization: 1,
      userId: 'user-01',
      conversationId: 'conversation-01',
      conversationType: 1,
      peerOrganization: 2,
      peerUserId: 'peer-01',
    );
    harness.connection.registerConversationIdentities([
      crossIdentityForPending,
    ]);
    expect(
      await harness.connection.consumeGlobalSync(
        nextGlobalSeq: harness.connection.bootstrap.nextGlobalSeq,
        consumer: (_) async => consumerCalled = true,
      ),
      isFalse,
    );
    expect(cursor.writes, isEmpty);
    expect(
      () =>
          harness.connection.registerConversationIdentities([_sameOrgIdentity]),
      throwsFormatException,
    );
    expect(
      () => harness.connection.sendTyping(crossIdentityForPending),
      throwsA(
        isA<AppImConnectionException>().having(
          (error) => error.code,
          'code',
          'IM_ACCESS_SNAPSHOT_UNSTABLE',
        ),
      ),
    );

    await subscription.cancel();
    await harness.connection.close();
    harness.api.close();
  });

  test('跨机构身份登记后 access 恢复会从未提交 cursor 重拉并消费原消息', () async {
    final cursor = _MemoryCursor('0', accessHighWater: '100');
    final socket = _MessagingSocket(
      authAccessSnapshotId: '99',
      syncSenderId: 'user-01',
      syncPages: const [
        (globalSeq: 1, hasMore: false, snapshotId: '99'),
        (globalSeq: 1, hasMore: false, snapshotId: '101'),
      ],
    );
    final harness = await _connectSocket(socket, cursor: cursor);
    const crossIdentityForPending = AppImConversationIdentityContext(
      organization: 1,
      userId: 'user-01',
      conversationId: 'conversation-01',
      conversationType: 1,
      peerOrganization: 2,
      peerUserId: 'peer-01',
    );
    harness.connection.registerConversationIdentities([
      crossIdentityForPending,
    ]);
    final requestedCursor = harness.connection.bootstrap.nextGlobalSeq;

    expect(
      await harness.connection.consumeGlobalSync(
        nextGlobalSeq: requestedCursor,
        consumer: (_) async {},
      ),
      isFalse,
    );
    expect(cursor.value, '0');

    final accessRecovered = harness.connection.events.firstWhere(
      (event) => event.accessChanged?.snapshotId == '101',
    );
    socket.pushRaw({
      'cmd': 'conversation.access_changed',
      'organization': 1,
      'data': {
        'event_id':
            '6767676767676767676767676767676767676767676767676767676767676767',
        'event_type': 'conversation.access_changed',
        'conversation_id': 'conversation-01',
        'conversation_type': 1,
        'cross_org_access_snapshot_id': '101',
        'allowed': true,
        'target_organization': 1,
        'target_user_id': 'user-01',
        'peer_organization': 2,
        'peer_user_id': 'peer-01',
      },
    });
    await accessRecovered.timeout(const Duration(seconds: 2));
    var delivered = const <AppImMessage>[];

    expect(
      await harness.connection.consumeGlobalSync(
        nextGlobalSeq: requestedCursor,
        consumer: (messages) async => delivered = messages,
      ),
      isTrue,
    );
    expect(delivered, hasLength(1));
    expect(delivered.single.senderId, 'user-01');
    expect(cursor.value, '1');
    expect(socket.globalSyncRequestCount, 2);
    expect(harness.connection.bootstrap.crossOrgAccessSnapshotId, '101');

    await harness.connection.close();
    harness.api.close();
  });

  test('未知单聊加载为同机构身份后重试同一 SYNC batch 且不丢消息', () async {
    final cursor = _MemoryCursor('0', accessHighWater: '100');
    final socket = _MessagingSocket(
      authAccessSnapshotId: '99',
      accessSnapshotId: '99',
      syncSenderId: 'user-01',
    );
    final harness = await _connectSocket(socket, cursor: cursor);
    var delivered = const <AppImMessage>[];

    expect(
      await harness.connection.consumeGlobalSync(
        nextGlobalSeq: harness.connection.bootstrap.nextGlobalSeq,
        consumer: (messages) async => delivered = messages,
      ),
      isFalse,
    );
    expect(delivered, isEmpty);
    expect(cursor.value, '0');

    harness.connection.registerConversationIdentities([_sameOrgIdentity]);
    expect(
      await harness.connection.consumeGlobalSync(
        nextGlobalSeq: harness.connection.bootstrap.nextGlobalSeq,
        consumer: (messages) async => delivered = messages,
      ),
      isTrue,
    );
    expect(delivered, hasLength(1));
    expect(delivered.single.senderId, 'user-01');
    expect(cursor.value, '4');
    expect(cursor.writes, ['4']);

    final sameOrgPush = harness.connection.events.firstWhere(
      (event) => event.message?.messageId == 'known-same-own-message-01',
    );
    socket.pushRaw({
      'cmd': 'push',
      'organization': 1,
      'data': {
        'event_id':
            '6565656565656565656565656565656565656565656565656565656565656565',
        'event_type': 'message.created',
        'message_id': 'known-same-own-message-01',
        'conversation_id': 'conversation-01',
        'message_seq': 2,
        'message': _message(
          messageId: 'known-same-own-message-01',
          clientMsgId: 'known-same-own-client-01',
          messageSeq: 2,
          globalSeq: '2',
          senderId: 'user-01',
          text: 'known same-org remains live',
        ),
      },
    });
    expect(
      (await sameOrgPush.timeout(
        const Duration(seconds: 2),
      )).message?.displayText,
      'known same-org remains live',
    );

    await harness.connection.close();
    harness.api.close();
  });

  test('fail-closed 时未知群聊 SYNC 仍可消费且 sender 必须留在 home', () async {
    final cursor = _MemoryCursor('0', accessHighWater: '100');
    final harness = await _connectSocket(
      _MessagingSocket(
        authAccessSnapshotId: '99',
        accessSnapshotId: '99',
        syncConversationType: 2,
      ),
      cursor: cursor,
    );
    var delivered = const <AppImMessage>[];

    expect(harness.connection.bootstrap.syncedMessages, hasLength(1));
    expect(
      await harness.connection.consumeGlobalSync(
        nextGlobalSeq: harness.connection.bootstrap.nextGlobalSeq,
        consumer: (messages) async => delivered = messages,
      ),
      isTrue,
    );
    expect(delivered.single.conversationType, 2);
    expect(delivered.single.senderOrganization, 1);
    expect(cursor.value, '4');

    await harness.connection.close();
    harness.api.close();
  });

  test('AUTH=100 与 SYNC=0 保持同机构连接并携带正快照高水位', () async {
    final socket = _MessagingSocket(
      authAccessSnapshotId: '100',
      syncPages: const [(globalSeq: 1, hasMore: false, snapshotId: '0')],
    );
    final harness = await _connectSocket(socket);

    expect(harness.connection.isConnected, isTrue);
    expect(harness.connection.bootstrap.crossOrgAccessSnapshotId, '0');
    expect(harness.connection.bootstrap.highestCrossOrgAccessSnapshotId, '100');

    await harness.connection.close();
    harness.api.close();
  });

  test('fail-closed 连接层丢弃跨机构 PUSH/receipt/read/mutation/typing', () async {
    final cursor = _MemoryCursor('0', accessHighWater: '100');
    final socket = _MessagingSocket(
      authAccessSnapshotId: '99',
      accessSnapshotId: '99',
    );
    final harness = await _connectSocket(socket, cursor: cursor);
    harness.connection.registerConversationIdentities([
      _crossOrgIdentity,
      const AppImConversationIdentityContext(
        organization: 1,
        userId: 'user-01',
        conversationId: 'same-org-live',
        conversationType: 1,
        peerOrganization: 1,
        peerUserId: 'peer-01',
      ),
    ]);
    final received = <AppImEvent>[];
    final subscription = harness.connection.events.listen(received.add);
    final sameOrgPush = harness.connection.events.firstWhere(
      (event) => event.message?.conversationId == 'same-org-live',
    );

    socket.pushCrossOrganizationSameId();
    socket.pushRaw({
      'cmd': 'ack',
      'organization': 1,
      'data': {
        'event_id':
            '5151515151515151515151515151515151515151515151515151515151515151',
        'event_type': 'message.receipt',
        'message_id': 'cross-message-01',
        'conversation_id': 'conversation-cross-01',
        'message_seq': 1,
        'sender_organization': 2,
        'sender_id': 'peer-01',
        'user_organization': 1,
        'user_id': 'user-01',
        'status': 'read',
        'time': '2026-07-20 12:00:00',
      },
    });
    socket.pushRaw({
      'cmd': 'conversation_read',
      'organization': 1,
      'data': {
        'event_id':
            '5252525252525252525252525252525252525252525252525252525252525252',
        'event_type': 'conversation.read',
        'conversation_id': 'conversation-cross-01',
        'last_read_message_id': 'cross-message-01',
        'last_read_seq': 1,
        'unread_count': 0,
        'user_organization': 2,
        'user_id': 'peer-01',
        'time': '2026-07-20 12:00:00',
      },
    });
    socket.pushRaw({
      'cmd': 'recall',
      'organization': 1,
      'data': {
        'event_id':
            '5353535353535353535353535353535353535353535353535353535353535353',
        'event_type': 'message.recalled',
        'conversation_id': 'conversation-cross-01',
        'message_id': 'cross-message-01',
        'message_seq': 1,
        'change_seq': 1,
        'actor_organization': 2,
        'actor_user_id': 'peer-01',
        'target_organization': null,
        'target_user_id': null,
        'status': 'recalled',
      },
    });
    socket.pushRaw({
      'cmd': 'typing',
      'organization': 1,
      'data': {
        'conversation_id': 'conversation-cross-01',
        'actor_organization': 2,
        'actor_user_id': 'peer-01',
        'username': '外部用户',
      },
    });
    socket.pushRaw({
      'cmd': 'conversation_read',
      'organization': 1,
      'data': {
        'event_id':
            '5555555555555555555555555555555555555555555555555555555555555555',
        'event_type': 'conversation.read',
        'conversation_id': 'conversation-cross-01',
        'last_read_message_id': 'cross-own-message-01',
        'last_read_seq': 2,
        'unread_count': 0,
        'user_organization': 1,
        'user_id': 'user-01',
        'time': '2026-07-20 12:00:00',
      },
    });
    socket.pushRaw({
      'cmd': 'recall',
      'organization': 1,
      'data': {
        'event_id':
            '5656565656565656565656565656565656565656565656565656565656565656',
        'event_type': 'message.recalled',
        'conversation_id': 'conversation-cross-01',
        'message_id': 'cross-own-message-01',
        'message_seq': 2,
        'change_seq': 2,
        'actor_organization': 1,
        'actor_user_id': 'user-01',
        'target_organization': null,
        'target_user_id': null,
        'status': 'recalled',
      },
    });
    socket.pushRaw({
      'cmd': 'typing',
      'organization': 1,
      'data': {
        'conversation_id': 'conversation-cross-01',
        'actor_organization': 1,
        'actor_user_id': 'user-01',
        'username': '当前用户',
      },
    });
    socket.pushRaw({
      'cmd': 'push',
      'organization': 1,
      'data': {
        'event_id':
            '5757575757575757575757575757575757575757575757575757575757575757',
        'event_type': 'message.created',
        'message_id': 'cross-screenshot-01',
        'conversation_id': 'conversation-cross-01',
        'message_seq': 3,
        'message': {
          ..._message(
            messageId: 'cross-screenshot-01',
            clientMsgId: 'cross-screenshot-client-01',
            messageSeq: 3,
            globalSeq: '3',
            conversationId: 'conversation-cross-01',
            senderId: 'system',
            text: '截屏提示',
          ),
          'message_type': 5,
          'content': {
            'text': '截屏提示',
            'actor_organization': 1,
            'actor_user_id': 'user-01',
          },
        },
      },
    });
    socket.pushRaw({
      'cmd': 'push',
      'organization': 1,
      'data': {
        'event_id':
            '5454545454545454545454545454545454545454545454545454545454545454',
        'event_type': 'message.created',
        'message_id': 'same-message-01',
        'conversation_id': 'same-org-live',
        'message_seq': 1,
        'message': _message(
          messageId: 'same-message-01',
          clientMsgId: 'same-client-01',
          messageSeq: 1,
          globalSeq: '2',
          conversationId: 'same-org-live',
          senderId: 'peer-01',
          text: 'same org remains live',
        ),
      },
    });

    await sameOrgPush.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received.single.message?.displayText, 'same org remains live');
    expect(harness.connection.isConnected, isTrue);

    await subscription.cancel();
    await harness.connection.close();
    harness.api.close();
  });

  test('AUTH/SYNC 期间 access=101 被缓冲并使旧 100 批次重跑', () async {
    final cursor = _MemoryCursor('0');
    final socket = _MessagingSocket(
      authAccessSnapshotId: '100',
      emitAccessChangeOnFirstGlobalSync: true,
      syncPages: const [
        (globalSeq: 1, hasMore: false, snapshotId: '100'),
        (globalSeq: 1, hasMore: false, snapshotId: '101'),
      ],
    );
    final harness = await _connectSocket(socket, cursor: cursor);
    await harness.connection.consumeGlobalSync(
      nextGlobalSeq: harness.connection.bootstrap.nextGlobalSeq,
      consumer: (_) async {},
    );

    expect(harness.connection.bootstrap.crossOrgAccessSnapshotId, '101');
    expect(harness.connection.recentAccessChanges, hasLength(1));
    expect(harness.connection.recentAccessChanges.single.snapshotId, '101');
    expect(cursor.writes, ['1']);

    await harness.connection.close();
    harness.api.close();
  });

  test('access event 同 snapshot 不丢不同 event_id，stale allow 不投递', () async {
    final socket = _MessagingSocket(
      authAccessSnapshotId: '100',
      syncPages: const [(globalSeq: 1, hasMore: false, snapshotId: '100')],
    );
    final harness = await _connectSocket(socket);
    final received = harness.connection.events
        .where((event) => event.accessChanged != null)
        .take(2)
        .toList();

    Map<String, Object?> accessData({
      required String eventId,
      required String snapshotId,
      required String conversationId,
      required bool allowed,
    }) => {
      'event_id': eventId,
      'event_type': 'conversation.access_changed',
      'conversation_id': conversationId,
      'conversation_type': 1,
      'cross_org_access_snapshot_id': snapshotId,
      'allowed': allowed,
      'target_organization': 1,
      'target_user_id': 'user-01',
      'peer_organization': 2,
      'peer_user_id': 'peer-01',
    };
    socket.pushRaw({
      'cmd': 'conversation.access_changed',
      'organization': 1,
      'data': accessData(
        eventId:
            '3131313131313131313131313131313131313131313131313131313131313131',
        snapshotId: '100',
        conversationId: 'single-cross-01',
        allowed: false,
      ),
    });
    socket.pushRaw({
      'cmd': 'conversation.access_changed',
      'organization': 1,
      'data': accessData(
        eventId:
            '3232323232323232323232323232323232323232323232323232323232323232',
        snapshotId: '99',
        conversationId: 'single-cross-01',
        allowed: true,
      ),
    });
    socket.pushRaw({
      'cmd': 'conversation.access_changed',
      'organization': 1,
      'data': accessData(
        eventId:
            '3333333333333333333333333333333333333333333333333333333333333333',
        snapshotId: '100',
        conversationId: 'single-cross-02',
        allowed: false,
      ),
    });

    final events = await received.timeout(const Duration(seconds: 2));
    expect(
      events.map((event) => event.eventId),
      containsAll([
        '3131313131313131313131313131313131313131313131313131313131313131',
        '3333333333333333333333333333333333333333333333333333333333333333',
      ]),
    );
    expect(
      events.every((event) => event.accessChanged!.allowed == false),
      isTrue,
    );
    expect(harness.connection.recentAccessChanges, hasLength(2));

    await harness.connection.close();
    harness.api.close();
  });

  test('conversation SYNC 以独立 client_msg_id 绑定双游标 ACK', () async {
    final socket = _MessagingSocket();
    final harness = await _connectSocket(socket);
    final page = await harness.connection.syncConversation(
      identity: _sameOrgIdentity,
      afterMessageSeq: 0,
      afterChangeSeq: 0,
    );

    expect(page.nextAfterMessageSeq, 4);
    expect(page.nextAfterChangeSeq, 1);
    expect(page.messages.single.messageId, 'message-04');
    expect(page.changes.single.changeType, 'edit');
    expect(socket.syncRequestIds, hasLength(2));
    expect(socket.syncRequestIds.toSet(), hasLength(2));

    await harness.connection.close();
    harness.api.close();
  });
}

Future<({AppImConnection connection, AppApiClient api})> _connectSocket(
  _MessagingSocket socket, {
  _MemoryCursor? cursor,
}) async {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final api = AppApiClient(
    httpClient: MockClient(
      (_) async => http.Response(
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
              'client_id': socket.clientId,
              'client_family': 'app',
              'os': 'ios',
              'session_id': 'abcdef0123456789abcdef0123456789',
              'exp': now + 60,
            }),
          },
        }),
        200,
      ),
    ),
  );
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
    cursorStore: cursor ?? _MemoryCursor('0'),
    socketFactory: (_) async => socket,
  );
  return (connection: connection, api: api);
}

final class _MemoryCursor implements ImSyncCursorGateway {
  _MemoryCursor(
    this.value, {
    this.accessHighWater = '0',
    this.blockAccessWriteCall = 0,
    this.blockCursorWriteCall = 0,
  });

  String value;
  String accessHighWater;
  final int blockAccessWriteCall;
  final int blockCursorWriteCall;
  final List<String> writes = [];
  final List<String> accessHighWaterWrites = [];
  final Completer<void> accessWriteEntered = Completer<void>();
  final Completer<void> releaseAccessWrite = Completer<void>();
  final Completer<void> cursorWriteEntered = Completer<void>();
  final Completer<void> releaseCursorWrite = Completer<void>();
  int _accessWriteCalls = 0;
  int _cursorWriteCalls = 0;

  @override
  Future<String> read(int organization, String userId) async => value;

  @override
  Future<bool> write(
    int organization,
    String userId,
    String cursor, {
    bool Function()? isCurrent,
  }) async {
    _cursorWriteCalls += 1;
    if (_cursorWriteCalls == blockCursorWriteCall) {
      if (!cursorWriteEntered.isCompleted) cursorWriteEntered.complete();
      await releaseCursorWrite.future;
    }
    if (isCurrent?.call() == false) return false;
    if (BigInt.parse(cursor) < BigInt.parse(value)) {
      throw StateError('global_seq cursor rollback');
    }
    writes.add(cursor);
    value = cursor;
    return true;
  }

  @override
  Future<String> readAccessSnapshotHighWater(
    int organization,
    String userId,
  ) async => accessHighWater;

  @override
  Future<bool> writeAccessSnapshotHighWater(
    int organization,
    String userId,
    String snapshotId, {
    bool Function()? isCurrent,
  }) async {
    _accessWriteCalls += 1;
    if (_accessWriteCalls == blockAccessWriteCall) {
      if (!accessWriteEntered.isCompleted) accessWriteEntered.complete();
      await releaseAccessWrite.future;
    }
    if (isCurrent?.call() == false) return false;
    if (BigInt.parse(snapshotId) > BigInt.parse(accessHighWater)) {
      accessHighWaterWrites.add(snapshotId);
      accessHighWater = snapshotId;
    }
    return true;
  }
}

typedef _BufferedAccessChange = ({
  String eventId,
  String snapshotId,
  String conversationId,
  bool allowed,
  int peerOrganization,
  String peerUserId,
});

final class _MessagingSocket implements ImSocket {
  _MessagingSocket({
    this.clientId = 'client-01',
    this.globalSeq = 4,
    this.syncSenderId = 'peer-01',
    this.syncSenderOrganization = 1,
    this.syncConversationType = 1,
    this.ackConversationOverride,
    this.ackSequenceOverride,
    this.ackSenderOrganizationOverride,
    this.ackSenderIdOverride,
    this.ackOverrideMessageId = 'cross-message-01',
    this.readMessageIdOverride,
    this.readSequenceOverride,
    this.accessSnapshotId = '1',
    this.authAccessSnapshotId,
    this.syncPages = const [],
    this.emitAccessChangeOnFirstGlobalSync = false,
    this.accessChangesOnFirstGlobalSync = const [],
    this.operationActorOrganizationOverride,
    this.deferScreenshotAck = false,
    this.syncMessageGlobalSeqOverride,
    this.screenshotEnabled = false,
    this.emitWrongGlobalSyncClientIdFirst = false,
  }) {
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
  final String syncSenderId;
  final int syncSenderOrganization;
  final int syncConversationType;
  final String? ackConversationOverride;
  final int? ackSequenceOverride;
  final int? ackSenderOrganizationOverride;
  final String? ackSenderIdOverride;
  final String ackOverrideMessageId;
  final String? readMessageIdOverride;
  final int? readSequenceOverride;
  final String accessSnapshotId;
  final String? authAccessSnapshotId;
  final List<({int globalSeq, bool hasMore, String snapshotId})> syncPages;
  final bool emitAccessChangeOnFirstGlobalSync;
  final List<_BufferedAccessChange> accessChangesOnFirstGlobalSync;
  final int? operationActorOrganizationOverride;
  final bool deferScreenshotAck;
  final String? syncMessageGlobalSeqOverride;
  final bool screenshotEnabled;
  final bool emitWrongGlobalSyncClientIdFirst;
  final StreamController<Object?> _controller = StreamController();
  final List<String> commands = [];
  Map<String, Object?>? _pendingScreenshotPacket;
  int screenshotRequestCount = 0;
  int globalSyncRequestCount = 0;
  final List<String> syncRequestIds = [];
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
              'cross_org_access_snapshot_id':
                  authAccessSnapshotId ?? accessSnapshotId,
            },
          }),
        );
      case 'sync':
        final requestId = packet['client_msg_id']! as String;
        syncRequestIds.add(requestId);
        final requestData = packet['data']! as Map<String, Object?>;
        if (requestData['conversation_id'] case final String conversationId) {
          _controller.add(
            jsonEncode({
              'cmd': 'sync_ack',
              'organization': 1,
              'client_msg_id': requestId,
              'data': {
                'organization': 1,
                'scope': 'conversation',
                'conversation_id': conversationId,
                'messages': [
                  _message(
                    messageId: 'message-04',
                    clientMsgId: 'remote-04',
                    messageSeq: 4,
                    globalSeq: '4',
                    senderId: syncSenderId,
                    senderOrganization: syncSenderOrganization,
                    conversationType: syncConversationType,
                    text: 'Synced conversation',
                  ),
                ],
                'changes': [
                  {
                    'conversation_id': conversationId,
                    'change_seq': 1,
                    'change_type': 'edit',
                    'message_id': 'message-04',
                    'message_seq': 4,
                    'actor_organization': 1,
                    'actor_user_id': syncSenderId,
                    'target_organization': null,
                    'target_user_id': null,
                    'payload': {
                      'content': {'text': 'Edited by sync'},
                      'edit_time': '2026-07-20 12:00:00',
                      'edit_count': 1,
                    },
                    'create_time': '2026-07-20 12:00:00',
                  },
                ],
                'next_after_seq': 4,
                'next_after_change_seq': 1,
                'messages_has_more': false,
                'changes_has_more': false,
                'cross_org_access_snapshot_id': accessSnapshotId,
              },
            }),
          );
          break;
        }
        final page = globalSyncRequestCount < syncPages.length
            ? syncPages[globalSyncRequestCount]
            : (
                globalSeq: globalSeq,
                hasMore: false,
                snapshotId: accessSnapshotId,
              );
        if (emitAccessChangeOnFirstGlobalSync && globalSyncRequestCount == 0) {
          pushRaw({
            'cmd': 'conversation.access_changed',
            'organization': 1,
            'data': {
              'event_id':
                  '1212121212121212121212121212121212121212121212121212121212121212',
              'event_type': 'conversation.access_changed',
              'conversation_id': 'single-cross-01',
              'conversation_type': 1,
              'cross_org_access_snapshot_id': '101',
              'allowed': false,
              'target_organization': 1,
              'target_user_id': 'user-01',
              'peer_organization': 2,
              'peer_user_id': 'peer-01',
            },
          });
        }
        if (globalSyncRequestCount == 0) {
          for (final accessChange in accessChangesOnFirstGlobalSync) {
            pushRaw({
              'cmd': 'conversation.access_changed',
              'organization': 1,
              'data': {
                'event_id': accessChange.eventId,
                'event_type': 'conversation.access_changed',
                'conversation_id': accessChange.conversationId,
                'conversation_type': 1,
                'cross_org_access_snapshot_id': accessChange.snapshotId,
                'allowed': accessChange.allowed,
                'target_organization': 1,
                'target_user_id': 'user-01',
                'peer_organization': accessChange.peerOrganization,
                'peer_user_id': accessChange.peerUserId,
              },
            });
          }
        }
        globalSyncRequestCount += 1;
        if (emitWrongGlobalSyncClientIdFirst && globalSyncRequestCount == 1) {
          _controller.add(
            jsonEncode({
              'cmd': 'sync_ack',
              'organization': 1,
              'client_msg_id': 'wrong-$requestId',
              'data': {
                'scope': 'global',
                'messages': const [],
                'next_after_global_seq': '999',
                'has_more': false,
                'cross_org_access_snapshot_id': '999',
              },
            }),
          );
        }
        _controller.add(
          jsonEncode({
            'cmd': 'sync_ack',
            'organization': 1,
            'client_msg_id': requestId,
            'data': {
              'scope': 'global',
              'messages': [
                _message(
                  messageId:
                      'message-${page.globalSeq.toString().padLeft(2, '0')}',
                  clientMsgId:
                      'remote-${page.globalSeq.toString().padLeft(2, '0')}',
                  messageSeq: page.globalSeq,
                  globalSeq:
                      syncMessageGlobalSeqOverride ?? '${page.globalSeq}',
                  senderId: syncSenderId,
                  senderOrganization: syncSenderOrganization,
                  conversationType: syncConversationType,
                  text: 'Synced',
                ),
              ],
              'next_after_global_seq': '${page.globalSeq}',
              'has_more': page.hasMore,
              'cross_org_access_snapshot_id': page.snapshotId,
            },
          }),
        );
      case 'send':
        final clientMsgId = packet['client_msg_id']! as String;
        final data = packet['data']! as Map<String, Object?>;
        expect(data['to_organization'], 1);
        final content = data['content']! as Map<String, Object?>;
        final messageType = data['message_type']! as int;
        _controller.add(
          jsonEncode({
            'cmd': 'send_ack',
            'organization': 1,
            'client_msg_id': clientMsgId,
            'data': {
              'ok': true,
              'duplicated': false,
              'organization': 1,
              'conversation_id': 'conversation-01',
              'message_id': messageType == 1 ? 'message-05' : 'message-06',
              'message_seq': messageType == 1 ? 5 : 6,
              'global_seq': messageType == 1 ? '5' : '6',
              'client_msg_id': clientMsgId,
              'message': messageType == 1
                  ? _message(
                      messageId: 'message-05',
                      clientMsgId: clientMsgId,
                      messageSeq: 5,
                      globalSeq: '5',
                      senderId: 'user-01',
                      text: content['text']! as String,
                    )
                  : _assetMessage(
                      messageId: 'message-06',
                      clientMsgId: clientMsgId,
                      messageSeq: 6,
                      globalSeq: '6',
                      senderId: 'user-01',
                      messageType: messageType,
                      fileId: content['file_id']! as String,
                    ),
            },
          }),
        );
      case 'ack':
        final data = packet['data']! as Map<String, Object?>;
        final status = data['status']! as String;
        final messageId = data['message_id']! as String;
        final metadata = _ackMetadata(messageId);
        final applyAckOverrides = messageId == ackOverrideMessageId;
        _controller.add(
          jsonEncode({
            'cmd': 'ack_ack',
            'organization': 1,
            'client_msg_id': packet['client_msg_id'],
            'data': {
              'message_id': messageId,
              'conversation_id': applyAckOverrides
                  ? ackConversationOverride ?? metadata.conversationId
                  : metadata.conversationId,
              'message_seq': applyAckOverrides
                  ? ackSequenceOverride ?? metadata.messageSeq
                  : metadata.messageSeq,
              'sender_organization': applyAckOverrides
                  ? ackSenderOrganizationOverride ?? metadata.senderOrganization
                  : metadata.senderOrganization,
              'sender_id': applyAckOverrides
                  ? ackSenderIdOverride ?? metadata.senderId
                  : metadata.senderId,
              'user_organization': 1,
              'user_id': 'user-01',
              'client_msg_id': packet['client_msg_id'],
              'request_client_msg_id': packet['client_msg_id'],
              'actor_organization': operationActorOrganizationOverride ?? 1,
              'actor_user_id': 'user-01',
              'status': status,
              'time': '2026-07-16 21:00:01',
            },
          }),
        );
      case 'conversation_read':
        final data = packet['data']! as Map<String, Object?>;
        final metadata = _ackMetadata(data['last_read_message_id']! as String);
        _controller.add(
          jsonEncode({
            'cmd': 'conversation_read_ack',
            'organization': 1,
            'client_msg_id': packet['client_msg_id'],
            'data': {
              'conversation_id': data['conversation_id'],
              'last_read_message_id':
                  readMessageIdOverride ?? data['last_read_message_id'],
              'last_read_seq': readSequenceOverride ?? metadata.messageSeq,
              'unread_count': 0,
              'user_organization': 1,
              'user_id': 'user-01',
              'time': '2026-07-16 21:00:01',
            },
          }),
        );
      case 'recall':
        final data = packet['data']! as Map<String, Object?>;
        _controller.add(
          jsonEncode({
            'cmd': 'recall_ack',
            'organization': 1,
            'client_msg_id': packet['client_msg_id'],
            'data': {
              'message_id': data['message_id'],
              'conversation_id': 'conversation-01',
              'recalled': true,
              'change_seq': 2,
              'client_msg_id': packet['client_msg_id'],
              'request_client_msg_id': packet['client_msg_id'],
              'actor_organization': operationActorOrganizationOverride ?? 1,
              'actor_user_id': 'user-01',
            },
          }),
        );
      case 'edit':
        final data = packet['data']! as Map<String, Object?>;
        final content = data['content']! as Map<String, Object?>;
        _controller.add(
          jsonEncode({
            'cmd': 'edit_ack',
            'organization': 1,
            'client_msg_id': packet['client_msg_id'],
            'data': {
              'message_id': data['message_id'],
              'conversation_id': 'conversation-01',
              'change_seq': 1,
              'client_msg_id': packet['client_msg_id'],
              'request_client_msg_id': packet['client_msg_id'],
              'actor_organization': operationActorOrganizationOverride ?? 1,
              'actor_user_id': 'user-01',
              'content': {'text': content['text']},
              'message': _message(
                messageId: data['message_id']! as String,
                clientMsgId: 'edited-client',
                messageSeq: 5,
                globalSeq: '5',
                senderId: 'user-01',
                text: content['text']! as String,
                editCount: 1,
                editTime: '2026-07-20 12:00:00',
              ),
            },
          }),
        );
      case 'delete':
        final data = packet['data']! as Map<String, Object?>;
        _controller.add(
          jsonEncode({
            'cmd': 'delete_ack',
            'organization': 1,
            'client_msg_id': packet['client_msg_id'],
            'data': {
              'message_id': data['message_id'],
              'conversation_id': 'conversation-01',
              'scope': data['scope'],
              'change_seq': 3,
              'client_msg_id': packet['client_msg_id'],
              'request_client_msg_id': packet['client_msg_id'],
              'actor_organization': operationActorOrganizationOverride ?? 1,
              'actor_user_id': 'user-01',
            },
          }),
        );
      case 'screenshot':
        screenshotRequestCount += 1;
        _pendingScreenshotPacket = packet;
        if (!deferScreenshotAck) completeScreenshot();
      case 'typing':
        break;
      case 'ping':
        _controller.add(
          jsonEncode({'cmd': 'pong', 'organization': 1, 'data': {}}),
        );
    }
  }

  void completeScreenshot() {
    final packet = _pendingScreenshotPacket;
    if (packet == null) return;
    _pendingScreenshotPacket = null;
    final data = packet['data']! as Map<String, Object?>;
    _controller.add(
      jsonEncode({
        'cmd': 'screenshot_ack',
        'organization': 1,
        'client_msg_id': packet['client_msg_id'],
        'data': {
          'conversation_id': data['conversation_id'],
          'enabled': screenshotEnabled,
          'notice_message': null,
          'client_msg_id': packet['client_msg_id'],
          'request_client_msg_id': packet['client_msg_id'],
          'actor_organization': operationActorOrganizationOverride ?? 1,
          'actor_user_id': 'user-01',
        },
      }),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  Future<void> remoteClose() => close();

  void pushRaw(Map<String, Object?> packet) {
    _controller.add(jsonEncode(packet));
  }

  void pushCrossOrganizationSameId() {
    _controller.add(
      jsonEncode({
        'cmd': 'push',
        'organization': 1,
        'data': {
          'event_id':
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'event_type': 'message.created',
          'message_id': 'cross-message-01',
          'conversation_id': 'single_cross',
          'message_seq': 7,
          'message': _message(
            messageId: 'cross-message-01',
            clientMsgId: 'cross-client-01',
            messageSeq: 7,
            globalSeq: '7',
            conversationId: 'single_cross',
            senderId: 'user-01',
            senderOrganization: 2,
            senderUser: {
              'organization': 2,
              'user_id': 'user-01',
              'account': 'external-same',
              'nickname': '外部同名用户',
              'avatar_url': '',
              'company_name': '外部公司',
              'organization_name': '外部机构',
              'is_cross_organization': true,
              'display_name': '',
            },
            text: 'Cross organization',
          ),
        },
      }),
    );
  }
}

({
  String conversationId,
  int messageSeq,
  int senderOrganization,
  String senderId,
})
_ackMetadata(String messageId) {
  if (messageId == 'cross-message-01') {
    return (
      conversationId: 'single_cross',
      messageSeq: 7,
      senderOrganization: 2,
      senderId: 'user-01',
    );
  }
  return (
    conversationId: 'conversation-01',
    messageSeq: int.tryParse(messageId.split('-').last) ?? 1,
    senderOrganization: 1,
    senderId: 'peer-01',
  );
}

Map<String, Object?> _message({
  required String messageId,
  required String clientMsgId,
  required int messageSeq,
  required String globalSeq,
  required String senderId,
  required String text,
  String conversationId = 'conversation-01',
  int senderOrganization = 1,
  int conversationType = 1,
  Map<String, Object?>? senderUser,
  int editCount = 0,
  String editTime = '',
}) => {
  'organization': 1,
  'global_seq': globalSeq,
  'conversation_id': conversationId,
  'conversation_type': conversationType,
  'message_id': messageId,
  'message_seq': messageSeq,
  'client_msg_id': clientMsgId,
  'sender_organization': senderOrganization,
  'sender_id': senderId,
  'sender_user': senderUser,
  'message_type': 1,
  'content': {'text': text},
  'status': 'normal',
  'edit_time': editTime,
  'edit_count': editCount,
  'create_time': '2026-07-16 21:00:00',
  'update_time': '2026-07-16 21:00:00',
};

Map<String, Object?> _assetMessage({
  required String messageId,
  required String clientMsgId,
  required int messageSeq,
  required String globalSeq,
  required String senderId,
  required int messageType,
  required String fileId,
  int senderOrganization = 1,
}) => {
  'organization': 1,
  'global_seq': globalSeq,
  'conversation_id': 'conversation-01',
  'conversation_type': 1,
  'message_id': messageId,
  'message_seq': messageSeq,
  'client_msg_id': clientMsgId,
  'sender_organization': senderOrganization,
  'sender_id': senderId,
  'sender_user': null,
  'message_type': messageType,
  'content': {
    'file_id': fileId,
    'name': 'photo.png',
    'size': 4,
    'mime_type': 'image/png',
    'extension': 'png',
  },
  'status': 'normal',
  'edit_time': '',
  'edit_count': 0,
  'create_time': '2026-07-16 21:00:00',
  'update_time': '2026-07-16 21:00:00',
};

const _sameOrgIdentity = AppImConversationIdentityContext(
  organization: 1,
  userId: 'user-01',
  conversationId: 'conversation-01',
  conversationType: 1,
  peerOrganization: 1,
  peerUserId: 'peer-01',
);
const _crossOrgIdentity = AppImConversationIdentityContext(
  organization: 1,
  userId: 'user-01',
  conversationId: 'conversation-cross-01',
  conversationType: 1,
  peerOrganization: 2,
  peerUserId: 'peer-01',
);
const _assetFileId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

String _jwt(Map<String, Object?> payload) {
  final header = base64Url
      .encode(utf8.encode(jsonEncode({'alg': 'none'})))
      .replaceAll('=', '');
  final body = base64Url
      .encode(utf8.encode(jsonEncode(payload)))
      .replaceAll('=', '');
  return '$header.$body.signature';
}
