import 'dart:async';

import 'package:b8im_app_flutter/src/app/b8im_app.dart';
import 'package:b8im_app_flutter/src/config/app_environment.dart';
import 'package:b8im_app_flutter/src/discovery/tenant_config.dart';
import 'package:b8im_app_flutter/src/discovery/tenant_discovery_client.dart';
import 'package:b8im_app_flutter/src/im/app_im_connection.dart';
import 'package:b8im_app_flutter/src/messaging/app_im_models.dart';
import 'package:b8im_app_flutter/src/messaging/app_messaging_service.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:b8im_app_flutter/src/session/app_session_bootstrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/tenant_fixture.dart';

final class _FakeDiscovery implements TenantDiscoveryGateway {
  @override
  Future<TenantConfig> discoverByDomain(String domain, {String? deviceId}) {
    return Future.value(tenantFixture());
  }

  @override
  Future<TenantConfig> discoverByEnterpriseCode(
    String enterpriseCode, {
    String? deviceId,
  }) {
    return Future.value(tenantFixture());
  }
}

final class _FakeSessionBootstrap implements AppSessionBootstrapGateway {
  _FakeSessionBootstrap(this.im);

  final AppImRuntime im;

  @override
  Future<AppSessionBootstrapResult> connect({
    required TenantConfig tenant,
    required String account,
    required String password,
    required String deviceId,
    required AppClientRuntime runtime,
  }) async {
    expect(account, 'acceptance');
    expect(password, 'secret');
    expect(deviceId, '0123456789abcdef0123456789abcdef');
    expect(runtime.os, 'ios');
    return AppSessionBootstrapResult(
      session: AppSession(
        accessToken: 'token',
        expireAt: 4102444800,
        organization: tenant.organization,
        deploymentId: tenant.deploymentId,
        deviceId: deviceId,
        runtime: runtime,
        user: const AppUser(
          id: '9',
          userId: 'user-01',
          account: 'acceptance',
          nickname: '验收用户',
        ),
      ),
      modules: const [],
      im: im,
    );
  }
}

final class _FakeImRuntime implements AppImRuntime {
  final StreamController<AppImEvent> controller = StreamController.broadcast();
  bool closed = false;

  @override
  AppImBootstrapSnapshot get bootstrap => const AppImBootstrapSnapshot(
    clientId: 'client-01',
    connectionSessionId: 'connection-01',
    credentialSessionId: 'credential-01',
    previousGlobalSeq: '0',
    nextGlobalSeq: '7',
    syncedMessages: [],
  );

  @override
  Stream<AppImEvent> get events => controller.stream;

  @override
  bool get isConnected => !closed;

  @override
  AppImConnectionStatus get connectionStatus =>
      closed ? AppImConnectionStatus.closed : AppImConnectionStatus.connected;

  @override
  Future<AppImReceipt> acknowledge({
    required String messageId,
    required AppImDeliveryStatus status,
  }) async => AppImReceipt(
    messageId: messageId,
    conversationId: 'conversation-01',
    messageSeq: 1,
    senderId: 'peer-01',
    userId: 'user-01',
    status: status,
    time: '2026-07-16 21:00:00',
  );

  @override
  Future<AppImConversationReadState> markConversationRead({
    required String conversationId,
    required String lastReadMessageId,
  }) async => AppImConversationReadState(
    conversationId: conversationId,
    lastReadMessageId: lastReadMessageId,
    lastReadSeq: 1,
    unreadCount: 0,
    userId: 'user-01',
    time: '2026-07-16 21:00:00',
  );

  @override
  Future<void> reconnect() async {}

  @override
  Future<AppImMessage> sendText({
    required int conversationType,
    required String text,
    String? conversationId,
    String? toUserId,
  }) async {
    expect(conversationType, 1);
    expect(conversationId, 'conversation-01');
    expect(toUserId, 'peer-01');
    return _message('message-02', 2, text, 'user-01');
  }

  @override
  Future<AppImMessage> sendAsset({
    required int conversationType,
    required int messageType,
    required String fileId,
    String? conversationId,
    String? toUserId,
  }) => throw UnimplementedError();

  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }
}

final class _FakeMessaging implements AppMessagingGateway {
  @override
  Future<List<AppImConversation>> fetchConversations({
    required TenantConfig tenant,
    required AppSession session,
  }) async => const [
    AppImConversation(
      conversationId: 'conversation-01',
      conversationType: 1,
      title: '测试好友',
      peerUser: AppImUserSummary(
        userId: 'peer-01',
        account: 'peer',
        nickname: '测试好友',
        avatarUrl: '',
      ),
      lastMessageId: 'message-01',
      lastMessageSeq: 1,
      lastMessageSummary: '历史消息',
      lastMessageTime: '2026-07-16 21:00:00',
      unreadCount: 1,
      isPinned: false,
      isMuted: false,
      avatarUrl: '',
    ),
  ];

  @override
  Future<AppImMessagePage> fetchMessages({
    required TenantConfig tenant,
    required AppSession session,
    required String conversationId,
    int beforeSeq = 0,
    int limit = 50,
  }) async => AppImMessagePage(
    messages: [_message('message-01', 1, '历史消息', 'peer-01')],
    nextAfterSeq: 1,
    nextBeforeSeq: 1,
    hasMoreBefore: false,
  );

  @override
  Future<int> markRead({
    required TenantConfig tenant,
    required AppSession session,
    required String conversationId,
  }) async => 1;
}

AppImMessage _message(
  String messageId,
  int sequence,
  String text,
  String senderId,
) => AppImMessage(
  organization: 1,
  globalSeq: '$sequence',
  conversationId: 'conversation-01',
  conversationType: 1,
  messageId: messageId,
  messageSeq: sequence,
  clientMsgId: 'client-$messageId',
  senderId: senderId,
  senderUser: null,
  messageType: 1,
  content: {'text': text},
  status: 'normal',
  editTime: '',
  editCount: 0,
  createTime: '2026-07-16 21:00:00',
  updateTime: '2026-07-16 21:00:00',
  deliveryStatus: senderId == 'user-01' ? AppImDeliveryStatus.sent : null,
);

void main() {
  testWidgets('使用企业码展示已验签的测试环境线路', (tester) async {
    final im = _FakeImRuntime();
    await tester.pumpWidget(
      B8imApp(
        environment: AppEnvironment(
          discoveryBaseUri: Uri.parse('https://api.idev.love'),
          routingPublicKeys: const {'test': 'public-key'},
          initialEnterpriseCode: 'org_1',
        ),
        discoveryGateway: _FakeDiscovery(),
        deviceIdLoader: () async => '0123456789abcdef0123456789abcdef',
        sessionBootstrapGateway: _FakeSessionBootstrap(im),
        messagingGateway: _FakeMessaging(),
        runtime: const AppClientRuntime(os: 'ios'),
      ),
    );

    expect(find.text('连接你的企业'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('discover-button')));
    await tester.pumpAndSettle();

    expect(find.text('b8im 测试机构'), findsOneWidget);
    expect(find.text('https://api.idev.love'), findsWidgets);
    expect(find.text('wss://ws.idev.love'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('login-account')).first,
      'acceptance',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login-password')).first,
      'secret',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('login-button')).first,
    );
    await tester.tap(find.byKey(const ValueKey('login-button')).first);
    await tester.pumpAndSettle();

    expect(find.text('AUTH + SYNC 已完成'), findsOneWidget);
    expect(find.text('验收用户 (acceptance)'), findsOneWidget);
    expect(find.text('0 → 7'), findsOneWidget);

    await tester.drag(find.byType(ListView).first, const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('open-messaging')));
    await tester.tap(find.byKey(const ValueKey('open-messaging')));
    await tester.pumpAndSettle();
    expect(find.text('测试好友'), findsOneWidget);
    expect(find.text('历史消息'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('conversation-conversation-01')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-message-01')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('message-composer')),
      'Flutter 发出的消息',
    );
    await tester.tap(find.byKey(const ValueKey('send-message')));
    await tester.pumpAndSettle();
    expect(find.text('Flutter 发出的消息'), findsOneWidget);
    expect(find.text('已发送'), findsOneWidget);
    im.controller.add(
      const AppImEvent(
        command: 'ack',
        message: null,
        eventId: null,
        receipt: AppImReceipt(
          messageId: 'message-02',
          conversationId: 'conversation-01',
          messageSeq: 2,
          senderId: 'user-01',
          userId: 'peer-01',
          status: AppImDeliveryStatus.read,
          time: '2026-07-16 21:00:01',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已读'), findsOneWidget);
  });
}
