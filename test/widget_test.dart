import 'dart:async';

import 'package:b8im_app_flutter/src/app/b8im_app.dart';
import 'package:b8im_app_flutter/src/config/app_environment.dart';
import 'package:b8im_app_flutter/src/contacts/app_contact_models.dart';
import 'package:b8im_app_flutter/src/contacts/app_contact_service.dart';
import 'package:b8im_app_flutter/src/contacts/contacts_page.dart';
import 'package:b8im_app_flutter/src/discovery/tenant_config.dart';
import 'package:b8im_app_flutter/src/discovery/tenant_discovery_client.dart';
import 'package:b8im_app_flutter/src/im/app_im_connection.dart';
import 'package:b8im_app_flutter/src/im/group_member_access.dart';
import 'package:b8im_app_flutter/src/media/app_media_picker.dart';
import 'package:b8im_app_flutter/src/media/app_media_service.dart';
import 'package:b8im_app_flutter/src/messaging/app_im_models.dart';
import 'package:b8im_app_flutter/src/messaging/app_messaging_service.dart';
import 'package:b8im_app_flutter/src/messaging/messaging_home_page.dart';
import 'package:b8im_app_flutter/src/qr_login/app_qr_login_service.dart';
import 'package:b8im_app_flutter/src/qr_login/web_login_qr_payload.dart';
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

final class _BrokenDiscovery implements TenantDiscoveryGateway {
  @override
  Future<TenantConfig> discoverByDomain(String domain, {String? deviceId}) {
    return Future.error(StateError('未配置 App 线路签名受信公钥'));
  }

  @override
  Future<TenantConfig> discoverByEnterpriseCode(
    String enterpriseCode, {
    String? deviceId,
  }) {
    return Future.error(StateError('未配置 App 线路签名受信公钥'));
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
  _FakeImRuntime({this.conversationSync, this.acknowledgeBarrier}) {
    _groupAccess.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '1',
        entries: {
          'group-01': GroupMemberAccessEntry(
            conversationId: 'group-01',
            accessVersion: '1',
            accessState: GroupMemberAccessState.active,
            lastMessageSeq: '100',
            lastChangeSeq: '100',
            periods: const [
              GroupMemberAccessPeriod(periodNo: '1', fromSeq: '1', toSeq: null),
            ],
          ),
        },
      ),
    );
  }

  final GroupMemberAccessRegistry _groupAccess = GroupMemberAccessRegistry(
    organization: 1,
    userId: 'user-01',
  );

  final Future<AppImConversationSyncPage> Function(
    String conversationId,
    int afterMessageSeq,
    int afterChangeSeq,
  )?
  conversationSync;
  final Future<void> Function()? acknowledgeBarrier;
  final StreamController<AppImEvent> controller = StreamController.broadcast(
    sync: true,
  );
  bool closed = false;
  AppImConnectionStatus _status = AppImConnectionStatus.connected;
  int _nextChangeSeq = 1;
  final List<({String messageId, AppImDeliveryStatus status})>
  acknowledgements = [];
  final Map<String, AppImConversationIdentityContext> registeredIdentities = {};
  Set<String> registeredConversationIdsAtLastConsume = const {};
  int conversationReadCount = 0;

  @override
  AppImBootstrapSnapshot get bootstrap => const AppImBootstrapSnapshot(
    clientId: 'client-01',
    connectionSessionId: 'connection-01',
    credentialSessionId: 'credential-01',
    crossOrgAccessSnapshotId: '1',
    highestCrossOrgAccessSnapshotId: '1',
    groupAccessSnapshotId: '1',
    previousGlobalSeq: '0',
    nextGlobalSeq: '7',
    syncedMessages: [],
  );

  @override
  Stream<AppImEvent> get events => controller.stream;

  @override
  List<AppImConversationAccessChanged> get recentAccessChanges => const [];

  @override
  bool get isConnected => !closed && _status == AppImConnectionStatus.connected;

  @override
  GroupMemberAccessSnapshot? get groupAccessSnapshot => _groupAccess.snapshot;

  @override
  bool get isGroupAccessReady => _groupAccess.isReady;

  @override
  AppImConnectionStatus get connectionStatus => _status;

  Future<void> publishGroupSnapshot(GroupMemberAccessSnapshot snapshot) async {
    final previous = _groupAccess.snapshot;
    await _groupAccess.replace(snapshot);
    controller.add(
      AppImEvent(
        command: groupMemberAccessSnapshotAckCommand,
        message: null,
        eventId: null,
        previousGroupAccessSnapshot: previous,
        groupAccessSnapshot: snapshot,
      ),
    );
  }

  void emitConnectionStatus(AppImConnectionStatus status) {
    _status = status;
    if (status != AppImConnectionStatus.connected) {
      _groupAccess.failClose();
    }
    controller.add(
      AppImEvent(
        command: 'connection_status',
        message: null,
        eventId: null,
        connectionStatus: status,
      ),
    );
  }

  @override
  void registerConversationIdentities(
    Iterable<AppImConversationIdentityContext> identities,
  ) {
    for (final identity in identities) {
      registeredIdentities[identity.conversationId] = identity;
    }
  }

  @override
  Future<bool> consumeGlobalSync({
    required String nextGlobalSeq,
    required Future<void> Function(List<AppImMessage> messages) consumer,
  }) async {
    registeredConversationIdsAtLastConsume = registeredIdentities.keys.toSet();
    await consumer(const []);
    return true;
  }

  @override
  Future<AppImReceipt> acknowledge({
    required AppImMessage message,
    required AppImDeliveryStatus status,
    required AppImConversationIdentityContext identity,
  }) async {
    acknowledgements.add((messageId: message.messageId, status: status));
    await acknowledgeBarrier?.call();
    return AppImReceipt(
      messageId: message.messageId,
      conversationId: message.conversationId,
      messageSeq: message.messageSeq,
      senderOrganization: message.senderOrganization,
      senderId: message.senderId,
      userOrganization: 1,
      userId: 'user-01',
      status: status,
      time: '2026-07-16 21:00:00',
    );
  }

  @override
  Future<AppImConversationReadState> markConversationRead({
    required AppImConversationIdentityContext identity,
    required AppImMessage lastReadMessage,
  }) async {
    conversationReadCount += 1;
    return AppImConversationReadState(
      conversationId: identity.conversationId,
      lastReadMessageId: lastReadMessage.messageId,
      lastReadSeq: lastReadMessage.messageSeq,
      unreadCount: 0,
      userOrganization: 1,
      userId: 'user-01',
      time: '2026-07-16 21:00:00',
    );
  }

  @override
  Future<void> reconnect() async {}

  @override
  Future<AppImConversationSyncPage> syncConversation({
    required AppImConversationIdentityContext identity,
    required int afterMessageSeq,
    required int afterChangeSeq,
    int limit = 100,
  }) async {
    final handler = conversationSync;
    if (handler != null) {
      return handler(identity.conversationId, afterMessageSeq, afterChangeSeq);
    }
    return AppImConversationSyncPage(
      conversationId: identity.conversationId,
      messages: const [],
      changes: const [],
      nextAfterMessageSeq: afterMessageSeq,
      nextAfterChangeSeq: afterChangeSeq,
      messagesHasMore: false,
      changesHasMore: false,
      crossOrgAccessSnapshotId: '1',
      groupAccessSnapshotId: '1',
      groupAccessVersion: identity.conversationType == 2 ? '1' : '',
      groupAccessState: identity.conversationType == 2 ? 'active' : null,
    );
  }

  @override
  Future<AppImMutationResult> recallMessage(
    AppImMessage message, {
    required AppImConversationIdentityContext identity,
  }) async {
    return AppImMutationResult(
      command: 'recall',
      conversationId: message.conversationId,
      messageId: message.messageId,
      messageSeq: message.messageSeq,
      changeSeq: _nextChangeSeq++,
      scope: '',
      status: 'recalled',
      message: null,
    );
  }

  @override
  Future<AppImMutationResult> editMessage(
    AppImMessage message,
    String text, {
    required AppImConversationIdentityContext identity,
  }) async {
    return AppImMutationResult(
      command: 'edit',
      conversationId: message.conversationId,
      messageId: message.messageId,
      messageSeq: message.messageSeq,
      changeSeq: _nextChangeSeq++,
      scope: '',
      status: '',
      message: message.copyWith(
        content: {'text': text},
        editCount: message.editCount + 1,
      ),
    );
  }

  @override
  Future<AppImMutationResult> deleteMessage(
    AppImMessage message, {
    required String scope,
    required AppImConversationIdentityContext identity,
  }) async {
    return AppImMutationResult(
      command: 'delete',
      conversationId: message.conversationId,
      messageId: message.messageId,
      messageSeq: message.messageSeq,
      changeSeq: _nextChangeSeq++,
      scope: scope,
      status: scope == 'both' ? 'deleted_both' : '',
      message: null,
    );
  }

  @override
  Future<AppImMessage?> sendScreenshot(
    AppImConversationIdentityContext identity,
  ) async => null;

  @override
  void sendTyping(AppImConversationIdentityContext identity) {}

  @override
  Future<AppImMessage> sendText({
    required int conversationType,
    required String text,
    String? conversationId,
    int? toOrganization,
    String? toUserId,
  }) async {
    expect(conversationType, 1);
    expect(conversationId, 'conversation-01');
    expect(toOrganization, 1);
    expect(toUserId, 'peer-01');
    return _message('message-02', 2, text, 'user-01');
  }

  @override
  Future<AppImMessage> sendAsset({
    required int conversationType,
    required int messageType,
    required String fileId,
    String? conversationId,
    int? toOrganization,
    String? toUserId,
  }) => throw UnimplementedError();

  @override
  Future<void> close() async {
    closed = true;
    _status = AppImConnectionStatus.closed;
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
        organization: 1,
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
    required int conversationType,
    required String conversationId,
    int peerOrganization = 0,
    String peerUserId = '',
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
    required int conversationType,
    required String conversationId,
  }) async => 1;
}

final class _FakeGroupMessaging implements AppMessagingGateway {
  _FakeGroupMessaging({List<AppImMessage>? messages})
    : messages = messages ?? [_groupMessage()];

  final List<AppImMessage> messages;
  bool failFetch = false;

  @override
  Future<List<AppImConversation>> fetchConversations({
    required TenantConfig tenant,
    required AppSession session,
  }) async {
    if (failFetch) throw StateError('authoritative group refresh failed');
    return const [
      AppImConversation(
        conversationId: 'group-01',
        conversationType: 2,
        title: '测试群聊',
        peerUser: null,
        lastMessageId: 'group-message-01',
        lastMessageSeq: 1,
        lastMessageSummary: '群消息',
        lastMessageTime: '2026-07-16 21:00:00',
        unreadCount: 0,
        isPinned: false,
        isMuted: false,
        avatarUrl: '',
      ),
    ];
  }

  @override
  Future<AppImMessagePage> fetchMessages({
    required TenantConfig tenant,
    required AppSession session,
    required int conversationType,
    required String conversationId,
    int peerOrganization = 0,
    String peerUserId = '',
    int beforeSeq = 0,
    int limit = 50,
  }) async {
    if (failFetch) throw StateError('authoritative group refresh failed');
    return AppImMessagePage(
      messages: messages,
      nextAfterSeq: messages.isEmpty ? 0 : messages.last.messageSeq,
      nextBeforeSeq: messages.isEmpty ? 0 : messages.first.messageSeq,
      hasMoreBefore: false,
    );
  }

  @override
  Future<int> markRead({
    required TenantConfig tenant,
    required AppSession session,
    required int conversationType,
    required String conversationId,
  }) async => 1;
}

final class _GapMessaging implements AppMessagingGateway {
  _GapMessaging({required this.failRefresh});

  final bool failRefresh;
  int fetchCount = 0;

  @override
  Future<List<AppImConversation>> fetchConversations({
    required TenantConfig tenant,
    required AppSession session,
  }) async => const [];

  @override
  Future<AppImMessagePage> fetchMessages({
    required TenantConfig tenant,
    required AppSession session,
    required int conversationType,
    required String conversationId,
    int peerOrganization = 0,
    String peerUserId = '',
    int beforeSeq = 0,
    int limit = 50,
  }) async {
    fetchCount += 1;
    if (fetchCount > 1 && failRefresh) {
      throw StateError('authoritative refresh failed');
    }
    return AppImMessagePage(
      messages: [
        _message(
          'message-gap',
          1,
          fetchCount == 1 ? '变更前' : '权威刷新结果',
          'user-01',
        ),
      ],
      nextAfterSeq: 1,
      nextBeforeSeq: 1,
      hasMoreBefore: false,
    );
  }

  @override
  Future<int> markRead({
    required TenantConfig tenant,
    required AppSession session,
    required int conversationType,
    required String conversationId,
  }) async => 0;
}

final class _CrossOrgMessaging implements AppMessagingGateway {
  _CrossOrgMessaging({this.messageCount = 1});

  final int messageCount;
  bool failFetch = false;
  int fetchCount = 0;
  int markReadCount = 0;

  @override
  Future<List<AppImConversation>> fetchConversations({
    required TenantConfig tenant,
    required AppSession session,
  }) async => const [];

  @override
  Future<AppImMessagePage> fetchMessages({
    required TenantConfig tenant,
    required AppSession session,
    required int conversationType,
    required String conversationId,
    int peerOrganization = 0,
    String peerUserId = '',
    int beforeSeq = 0,
    int limit = 50,
  }) async {
    fetchCount += 1;
    if (failFetch) throw StateError('authoritative access refresh failed');
    return AppImMessagePage(
      messages: List.generate(messageCount, _crossOrgMessage),
      nextAfterSeq: messageCount,
      nextBeforeSeq: messageCount,
      hasMoreBefore: false,
    );
  }

  @override
  Future<int> markRead({
    required TenantConfig tenant,
    required AppSession session,
    required int conversationType,
    required String conversationId,
  }) async {
    markReadCount += 1;
    return 0;
  }
}

final class _UnusedMedia implements AppMediaGateway {
  @override
  Future<String> download({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required int conversationType,
    required String conversationId,
    required String messageId,
    required int messageSeq,
    required String filename,
  }) => throw UnimplementedError();

  @override
  Future<Uri> resolve({
    required TenantConfig tenant,
    required AppSession session,
    required String fileId,
    required int conversationType,
    required String conversationId,
    required String messageId,
    required int messageSeq,
  }) => throw UnimplementedError();

  @override
  Future<AppMediaUpload> upload({
    required TenantConfig tenant,
    required AppSession session,
    required AppMediaKind kind,
    required int conversationType,
    required String conversationId,
    required String filePath,
    required String filename,
    required int size,
    required String mimeType,
  }) => throw UnimplementedError();
}

final class _UnusedQrLogin implements AppQrLoginGateway {
  @override
  Future<WebLoginScanResult> scan({
    required TenantConfig tenant,
    required AppSession session,
    required WebLoginQrPayload payload,
  }) => throw UnimplementedError();

  @override
  Future<void> confirm({
    required TenantConfig tenant,
    required AppSession session,
    required String qrId,
  }) => throw UnimplementedError();
}

final class _UnusedMediaPicker implements AppMediaPickerGateway {
  @override
  Future<AppPickedMedia?> pick(AppMediaKind kind) async => null;
}

class _FakeContacts implements AppContactGateway {
  const _FakeContacts({
    this.contacts = const [
      AppContact(
        id: '2',
        organization: 1,
        organizationName: '测试机构',
        companyName: '测试机构',
        isCrossOrganization: false,
        userId: 'peer-01',
        account: 'peer',
        nickname: '测试好友',
        signature: '产品部',
        avatarUrl: '',
        mobile: '',
        imShortNo: '10002',
        statusText: '正常',
        remark: '',
        relationStatus: 'friend',
        isSystem: false,
      ),
    ],
    this.requests = const [],
  });

  final List<AppContact> contacts;
  final List<AppFriendRequest> requests;

  @override
  Future<List<AppContact>> fetchContacts({
    required TenantConfig tenant,
    required AppSession session,
    String keyword = '',
  }) async => contacts;

  @override
  Future<List<AppFriendRequest>> fetchFriendRequests({
    required TenantConfig tenant,
    required AppSession session,
  }) async => requests;

  @override
  Future<List<AppContact>> searchUsers({
    required TenantConfig tenant,
    required AppSession session,
    required String keyword,
  }) async => fetchContacts(tenant: tenant, session: session);

  @override
  Future<String> sendFriendRequest({
    required TenantConfig tenant,
    required AppSession session,
    required int organization,
    required String userId,
    required String message,
  }) async => '已是好友';

  @override
  Future<void> handleFriendRequest({
    required TenantConfig tenant,
    required AppSession session,
    required AppFriendRequest request,
    required bool accept,
  }) async {}
}

final class _ToggleContacts extends _FakeContacts {
  _ToggleContacts({required super.contacts, super.requests});

  bool failFetch = false;
  int handleCount = 0;
  int contactsFetchCount = 0;
  int requestsFetchCount = 0;
  Completer<void>? contactsBarrier;
  Completer<void>? requestsBarrier;

  @override
  Future<List<AppContact>> fetchContacts({
    required TenantConfig tenant,
    required AppSession session,
    String keyword = '',
  }) async {
    contactsFetchCount += 1;
    await contactsBarrier?.future;
    if (failFetch) throw StateError('authoritative contacts refresh failed');
    return super.fetchContacts(
      tenant: tenant,
      session: session,
      keyword: keyword,
    );
  }

  @override
  Future<List<AppFriendRequest>> fetchFriendRequests({
    required TenantConfig tenant,
    required AppSession session,
  }) async {
    requestsFetchCount += 1;
    await requestsBarrier?.future;
    if (failFetch) throw StateError('authoritative requests refresh failed');
    return super.fetchFriendRequests(tenant: tenant, session: session);
  }

  @override
  Future<void> handleFriendRequest({
    required TenantConfig tenant,
    required AppSession session,
    required AppFriendRequest request,
    required bool accept,
  }) async {
    handleCount += 1;
  }
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
  senderOrganization: 1,
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

AppImMessage _groupMessage() => const AppImMessage(
  organization: 1,
  globalSeq: '1',
  conversationId: 'group-01',
  conversationType: 2,
  messageId: 'group-message-01',
  messageSeq: 1,
  clientMsgId: 'group-client-01',
  senderOrganization: 1,
  senderId: 'user-01',
  senderUser: null,
  messageType: 1,
  content: {'text': '群消息'},
  status: 'normal',
  editTime: '',
  editCount: 0,
  createTime: '2026-07-16 21:00:00',
  updateTime: '2026-07-16 21:00:00',
  deliveryStatus: AppImDeliveryStatus.sent,
);

AppImMessage _groupMessageAt(int sequence, String text) => AppImMessage(
  organization: 1,
  globalSeq: '$sequence',
  conversationId: 'group-01',
  conversationType: 2,
  messageId: 'group-message-$sequence',
  messageSeq: sequence,
  clientMsgId: 'group-client-$sequence',
  senderOrganization: 1,
  senderId: 'user-01',
  senderUser: null,
  messageType: 1,
  content: {'text': text},
  status: 'normal',
  editTime: '',
  editCount: 0,
  createTime: '2026-07-16 21:00:00',
  updateTime: '2026-07-16 21:00:00',
  deliveryStatus: AppImDeliveryStatus.sent,
);

AppImMessage _crossOrgMessage(int index) => AppImMessage(
  organization: 1,
  globalSeq: '${index + 1}',
  conversationId: 'cross-conversation-01',
  conversationType: 1,
  messageId: 'cross-message-${index + 1}',
  messageSeq: index + 1,
  clientMsgId: 'cross-client-${index + 1}',
  senderOrganization: 2,
  senderId: 'external-01',
  senderUser: null,
  messageType: 1,
  content: {'text': '跨机构历史 ${index + 1}'},
  status: 'normal',
  editTime: '',
  editCount: 0,
  createTime: '2026-07-20 12:00:00',
  updateTime: '2026-07-20 12:00:00',
  deliveryStatus: null,
);

const _singleConversation = AppImConversation(
  conversationId: 'conversation-01',
  conversationType: 1,
  title: '测试好友',
  peerUser: AppImUserSummary(
    organization: 1,
    userId: 'peer-01',
    account: 'peer',
    nickname: '测试好友',
    avatarUrl: '',
  ),
  lastMessageId: 'message-gap',
  lastMessageSeq: 1,
  lastMessageSummary: '变更前',
  lastMessageTime: '2026-07-20 12:00:00',
  unreadCount: 0,
  isPinned: false,
  isMuted: false,
  avatarUrl: '',
);

const _groupConversation = AppImConversation(
  conversationId: 'group-01',
  conversationType: 2,
  title: '测试群聊',
  peerUser: null,
  lastMessageId: 'group-message-01',
  lastMessageSeq: 1,
  lastMessageSummary: '群消息',
  lastMessageTime: '2026-07-16 21:00:00',
  unreadCount: 0,
  isPinned: false,
  isMuted: false,
  avatarUrl: '',
);

const _crossOrgConversation = AppImConversation(
  conversationId: 'cross-conversation-01',
  conversationType: 1,
  title: '外部好友',
  peerUser: AppImUserSummary(
    organization: 2,
    userId: 'external-01',
    account: 'external',
    nickname: '外部好友',
    avatarUrl: '',
  ),
  lastMessageId: 'cross-message-1',
  lastMessageSeq: 1,
  lastMessageSummary: '跨机构历史 1',
  lastMessageTime: '2026-07-20 12:00:00',
  unreadCount: 1,
  isPinned: false,
  isMuted: false,
  avatarUrl: '',
);

const _externalContact = AppContact(
  id: '20',
  organization: 2,
  organizationName: '外部机构',
  companyName: '外部公司',
  isCrossOrganization: true,
  userId: 'external-01',
  account: 'external',
  nickname: '外部好友',
  signature: '',
  avatarUrl: '',
  mobile: '',
  imShortNo: '20001',
  statusText: '正常',
  remark: '',
  relationStatus: 'friend',
  isSystem: false,
);

const _externalFriendRequest = AppFriendRequest(
  id: 30,
  direction: 'incoming',
  message: '申请添加好友',
  status: 1,
  statusText: '待处理',
  createTime: '2026-07-20 12:00:00',
  fromOrganization: 2,
  toOrganization: 1,
  fromUser: _externalContact,
  toUser: null,
);

AppSession _testSession(TenantConfig tenant) => AppSession(
  accessToken: 'token',
  expireAt: 4102444800,
  organization: 1,
  deploymentId: tenant.deploymentId,
  deviceId: '0123456789abcdef0123456789abcdef',
  runtime: const AppClientRuntime(os: 'ios'),
  user: const AppUser(
    id: '9',
    userId: 'user-01',
    account: 'acceptance',
    nickname: '验收用户',
  ),
);

AppImEvent _crossOrgAccessEvent(String snapshotId, bool allowed) => AppImEvent(
  command: 'conversation.access_changed',
  message: null,
  eventId: snapshotId.padLeft(64, '0'),
  accessChanged: AppImConversationAccessChanged(
    eventId: snapshotId.padLeft(64, '0'),
    snapshotId: snapshotId,
    conversationId: 'cross-conversation-01',
    allowed: allowed,
    targetOrganization: 1,
    targetUserId: 'user-01',
    peerOrganization: 2,
    peerUserId: 'external-01',
  ),
);

AppImEvent _friendControlEvent(String eventId, String event) {
  final created = event == 'created';
  final accepted = event == 'accepted';
  final changed = AppImFriendRequestChanged(
    eventId: eventId,
    event: event,
    requestId: 30,
    status: created ? 1 : (accepted ? 2 : 3),
    fromOrganization: created ? 2 : 1,
    fromUserId: created ? 'external-01' : 'user-01',
    toOrganization: created ? 1 : 2,
    toUserId: created ? 'user-01' : 'external-01',
    targetOrganization: 1,
    targetUserId: 'user-01',
    actorOrganization: 2,
    actorUserId: 'external-01',
    crossOrgAccessSnapshotId: '1',
    createTime: '2026-07-21 10:00:00',
    handleTime: created ? null : '2026-07-21 10:01:00',
  );
  return AppImEvent(
    command: 'friend_request',
    message: null,
    eventId: eventId,
    friendRequest: changed,
  );
}

void main() {
  testWidgets('连接异常不会向用户暴露内部错误', (tester) async {
    await tester.pumpWidget(
      B8imApp(
        environment: AppEnvironment(
          discoveryBaseUri: Uri.parse('https://api.idev.love'),
          routingPublicKeys: const {},
          initialEnterpriseCode: 'org_1',
        ),
        discoveryGateway: _BrokenDiscovery(),
        deviceIdLoader: () async => '0123456789abcdef0123456789abcdef',
        sessionBootstrapGateway: _FakeSessionBootstrap(_FakeImRuntime()),
        messagingGateway: _FakeMessaging(),
        contactGateway: _FakeContacts(),
        runtime: const AppClientRuntime(os: 'ios'),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('discover-button')));
    await tester.pumpAndSettle();

    expect(find.text('客户端安全配置异常，请更新 App 后重试'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('受信公钥'), findsNothing);
  });

  testWidgets('企业接入后登录并直接进入消息', (tester) async {
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
        contactGateway: _FakeContacts(),
        runtime: const AppClientRuntime(os: 'ios'),
      ),
    );

    expect(find.text('欢迎使用 B8 IM'), findsOneWidget);
    expect(find.text('发现服务'), findsNothing);
    expect(find.text('App 模块注册数'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('discover-button')));
    await tester.pumpAndSettle();

    expect(find.text('b8im 测试机构'), findsOneWidget);
    expect(find.text('登录企业账号'), findsOneWidget);
    expect(find.text('https://api.idev.love'), findsNothing);
    expect(find.text('wss://ws.idev.love'), findsNothing);
    expect(find.text('Organization'), findsNothing);
    expect(find.text('Deployment'), findsNothing);

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

    expect(find.text('AUTH + SYNC 已完成'), findsNothing);
    expect(find.text('0 → 7'), findsNothing);
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('通讯录'), findsOneWidget);
    expect(find.text('发现'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('open-web-login-scanner')),
      findsOneWidget,
    );
    expect(find.text('测试好友'), findsOneWidget);
    expect(find.text('历史消息'), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
    expect(
      im.registeredConversationIdsAtLastConsume,
      contains('conversation-01'),
    );

    im.controller.add(
      AppImEvent(
        command: 'push',
        message: _message('message-authoritative', 3, '合法推送', 'peer-01'),
        eventId: 'valid-push',
      ),
    );
    im.controller.add(
      AppImEvent(
        command: 'push',
        message: _message('message-forged', 4, '第三方伪造', 'third-party'),
        eventId: 'forged-push',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      im.acknowledgements
          .where((item) => item.status == AppImDeliveryStatus.delivered)
          .map((item) => item.messageId),
      ['message-authoritative'],
    );

    await tester.tap(find.byKey(const ValueKey('bottom-tab-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('contacts-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-1-peer-01')), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);

    await tester.tap(find.byKey(const ValueKey('bottom-tab-0')));
    await tester.pumpAndSettle();

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
        eventId: 'cross-org-receipt',
        receipt: AppImReceipt(
          messageId: 'message-02',
          conversationId: 'conversation-01',
          messageSeq: 2,
          senderOrganization: 1,
          senderId: 'user-01',
          userOrganization: 2,
          userId: 'peer-01',
          status: AppImDeliveryStatus.read,
          time: '2026-07-16 21:00:01',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('已发送'), findsOneWidget);
    expect(find.text('已读'), findsNothing);
    im.controller.add(
      const AppImEvent(
        command: 'typing',
        message: null,
        eventId: null,
        typing: AppImTypingState(
          conversationId: 'conversation-01',
          actorOrganization: 2,
          actorUserId: 'peer-01',
          username: '伪造同名用户',
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing-indicator')), findsNothing);
    im.controller.add(
      const AppImEvent(
        command: 'typing',
        message: null,
        eventId: null,
        typing: AppImTypingState(
          conversationId: 'conversation-01',
          actorOrganization: 1,
          actorUserId: 'peer-01',
          username: '测试好友',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('测试好友 正在输入…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('typing-indicator')), findsNothing);
    im.controller.add(
      const AppImEvent(
        command: 'ack',
        message: null,
        eventId: null,
        receipt: AppImReceipt(
          messageId: 'message-02',
          conversationId: 'conversation-01',
          messageSeq: 2,
          senderOrganization: 1,
          senderId: 'user-01',
          userOrganization: 1,
          userId: 'peer-01',
          status: AppImDeliveryStatus.read,
          time: '2026-07-16 21:00:01',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已读'), findsOneWidget);
    im.controller.add(
      AppImEvent(
        command: 'edit',
        message: null,
        eventId: 'cross-org-edit',
        mutation: const AppImMessageMutation(
          command: 'edit',
          eventId: 'cross-org-edit',
          eventType: 'message.edited',
          conversationId: 'conversation-01',
          messageId: 'message-02',
          messageSeq: 2,
          changeSeq: 1,
          actorOrganization: 2,
          actorUserId: 'user-01',
          targetOrganization: null,
          targetUserId: null,
          scope: '',
          status: '',
          message: null,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Flutter 发出的消息'), findsOneWidget);
    im.controller.add(
      AppImEvent(
        command: 'edit',
        message: null,
        eventId: 'valid-edit',
        mutation: AppImMessageMutation(
          command: 'edit',
          eventId: 'valid-edit',
          eventType: 'message.edited',
          conversationId: 'conversation-01',
          messageId: 'message-02',
          messageSeq: 2,
          changeSeq: 1,
          actorOrganization: 1,
          actorUserId: 'user-01',
          targetOrganization: null,
          targetUserId: null,
          scope: '',
          status: '',
          message: _message('message-02', 2, '已编辑消息', 'user-01'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('已编辑消息'), findsOneWidget);
  });

  testWidgets('群聊成员的个人 receipt/read 不推进整群已读', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final session = AppSession(
      accessToken: 'token',
      expireAt: 4102444800,
      organization: 1,
      deploymentId: tenant.deploymentId,
      deviceId: '0123456789abcdef0123456789abcdef',
      runtime: const AppClientRuntime(os: 'ios'),
      user: const AppUser(
        id: '9',
        userId: 'user-01',
        account: 'acceptance',
        nickname: '验收用户',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          tenant: tenant,
          session: session,
          im: im,
          messaging: _FakeGroupMessaging(),
          conversation: const AppImConversation(
            conversationId: 'group-01',
            conversationType: 2,
            title: '测试群聊',
            peerUser: null,
            lastMessageId: 'group-message-01',
            lastMessageSeq: 1,
            lastMessageSummary: '群消息',
            lastMessageTime: '2026-07-16 21:00:00',
            unreadCount: 0,
            isPinned: false,
            isMuted: false,
            avatarUrl: '',
          ),
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已发送'), findsOneWidget);
    im.controller.add(
      const AppImEvent(
        command: 'ack',
        message: null,
        eventId: 'group-receipt',
        receipt: AppImReceipt(
          messageId: 'group-message-01',
          conversationId: 'group-01',
          messageSeq: 1,
          senderOrganization: 1,
          senderId: 'user-01',
          userOrganization: 1,
          userId: 'member-02',
          status: AppImDeliveryStatus.read,
          time: '2026-07-20 12:00:00',
        ),
      ),
    );
    im.controller.add(
      const AppImEvent(
        command: 'conversation_read',
        message: null,
        eventId: 'group-read',
        conversationRead: AppImConversationReadState(
          conversationId: 'group-01',
          lastReadMessageId: 'group-message-01',
          lastReadSeq: 1,
          unreadCount: 0,
          userOrganization: 1,
          userId: 'member-02',
          time: '2026-07-20 12:00:00',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('已发送'), findsOneWidget);
    expect(find.text('已读'), findsNothing);

    im.controller.add(
      const AppImEvent(
        command: groupMemberAccessChangedCommand,
        message: null,
        eventId: 'group-history-only',
        groupAccessChanged: GroupMemberAccessChanged(
          eventId: 'group-history-only',
          snapshotId: '2',
          entry: GroupMemberAccessEntry(
            conversationId: 'group-01',
            accessVersion: '2',
            accessState: GroupMemberAccessState.historyOnly,
            lastMessageSeq: '1',
            lastChangeSeq: '1',
            periods: [
              GroupMemberAccessPeriod(periodNo: '1', fromSeq: '1', toSeq: '1'),
            ],
          ),
          reason: 'leave',
          changedAt: '2026-07-20 12:00:01',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('群消息'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('message-composer')))
          .enabled,
      isFalse,
    );

    im.controller.add(
      const AppImEvent(
        command: groupMemberAccessChangedCommand,
        message: null,
        eventId: 'group-revoked',
        groupAccessChanged: GroupMemberAccessChanged(
          eventId: 'group-revoked',
          snapshotId: '3',
          entry: GroupMemberAccessEntry(
            conversationId: 'group-01',
            accessVersion: '3',
            accessState: GroupMemberAccessState.revoked,
            lastMessageSeq: '1',
            lastChangeSeq: '1',
            periods: [],
          ),
          reason: 'history_revoke',
          changedAt: '2026-07-20 12:00:02',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('群消息'), findsNothing);
    expect(find.text('群会话访问已撤销'), findsOneWidget);
  });

  testWidgets('群快照撤权在会话列表 HTTP 失败前同步清除', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final messaging = _FakeGroupMessaging();
    await tester.pumpWidget(
      MaterialApp(
        home: MessagingHomePage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          messaging: messaging,
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
          qrLogin: _UnusedQrLogin(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试群聊'), findsOneWidget);

    messaging.failFetch = true;
    await im.publishGroupSnapshot(
      GroupMemberAccessSnapshot(snapshotId: '2', entries: const {}),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试群聊'), findsNothing);
    expect(
      find.textContaining('authoritative group refresh failed'),
      findsOneWidget,
    );
  });

  testWidgets('history_only 快照先裁剪周期外消息，HTTP 失败也不复活', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final messaging = _FakeGroupMessaging(
      messages: [_groupMessageAt(1, '保留的群消息'), _groupMessageAt(15, '必须裁剪的群消息')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          messaging: messaging,
          conversation: _groupConversation,
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保留的群消息'), findsOneWidget);
    expect(find.text('必须裁剪的群消息'), findsOneWidget);

    messaging.failFetch = true;
    await im.publishGroupSnapshot(
      GroupMemberAccessSnapshot(
        snapshotId: '2',
        entries: {
          'group-01': GroupMemberAccessEntry(
            conversationId: 'group-01',
            accessVersion: '2',
            accessState: GroupMemberAccessState.historyOnly,
            lastMessageSeq: '15',
            lastChangeSeq: '101',
            periods: const [
              GroupMemberAccessPeriod(periodNo: '1', fromSeq: '1', toSeq: '10'),
            ],
          ),
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('保留的群消息'), findsOneWidget);
    expect(find.text('必须裁剪的群消息'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('message-composer')))
          .enabled,
      isFalse,
    );
    expect(
      find.textContaining('authoritative group refresh failed'),
      findsOneWidget,
    );
  });

  testWidgets('群 reconnect 新 active 快照补充失败时仍保持 fail-closed', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final messaging = _FakeGroupMessaging();
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          messaging: messaging,
          conversation: _groupConversation,
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('message-composer')),
      '不应跨重连保留',
    );

    im.emitConnectionStatus(AppImConnectionStatus.reconnecting);
    await tester.pump();
    expect(find.text('群消息'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('message-composer')))
          .controller
          ?.text,
      isEmpty,
    );

    messaging.failFetch = true;
    await im.publishGroupSnapshot(
      GroupMemberAccessSnapshot(
        snapshotId: '2',
        entries: {
          'group-01': GroupMemberAccessEntry(
            conversationId: 'group-01',
            accessVersion: '2',
            accessState: GroupMemberAccessState.active,
            lastMessageSeq: '100',
            lastChangeSeq: '101',
            periods: const [
              GroupMemberAccessPeriod(periodNo: '1', fromSeq: '1', toSeq: null),
            ],
          ),
        },
      ),
    );
    im.emitConnectionStatus(AppImConnectionStatus.connected);
    await tester.pumpAndSettle();

    expect(find.text('群消息'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('message-composer')))
          .enabled,
      isFalse,
    );
    expect(
      find.textContaining('authoritative group refresh failed'),
      findsOneWidget,
    );
  });

  testWidgets('conversation_read 目标不在 50 条缓存时仍按已验证 seq 推进', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          messaging: _GapMessaging(failRefresh: false),
          conversation: _singleConversation,
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已发送'), findsOneWidget);

    im.controller.add(
      const AppImEvent(
        command: 'conversation_read',
        message: null,
        eventId: 'read-evicted-message',
        conversationRead: AppImConversationReadState(
          conversationId: 'conversation-01',
          lastReadMessageId: 'message-outside-cache',
          lastReadSeq: 99,
          unreadCount: 0,
          userOrganization: 1,
          userId: 'peer-01',
          time: '2026-07-20 12:00:00',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('已读'), findsOneWidget);
  });

  testWidgets('乱序 change_seq 触发权威历史刷新并忽略随后 stale 事件', (tester) async {
    final im = _FakeImRuntime(
      conversationSync:
          (conversationId, afterMessageSeq, afterChangeSeq) async =>
              AppImConversationSyncPage(
                conversationId: conversationId,
                messages: [_message('message-gap', 1, '变更前', 'user-01')],
                changes: const [
                  AppImSyncedMessageChange(
                    conversationId: 'conversation-01',
                    changeSeq: 2,
                    changeType: 'edit',
                    messageId: 'message-gap',
                    messageSeq: 1,
                    actorOrganization: 1,
                    actorUserId: 'user-01',
                    targetOrganization: null,
                    targetUserId: null,
                    payload: {
                      'content': {'text': '权威刷新结果'},
                      'edit_time': '2026-07-20 12:00:00',
                      'edit_count': 1,
                    },
                    createTime: '2026-07-20 12:00:00',
                  ),
                ],
                nextAfterMessageSeq: 1,
                nextAfterChangeSeq: 2,
                messagesHasMore: false,
                changesHasMore: false,
                crossOrgAccessSnapshotId: '1',
                groupAccessSnapshotId: '1',
                groupAccessVersion: '',
                groupAccessState: null,
              ),
    );
    final tenant = tenantFixture();
    final messaging = _GapMessaging(failRefresh: false);
    final session = _testSession(tenant);
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          tenant: tenant,
          session: session,
          im: im,
          messaging: messaging,
          conversation: _singleConversation,
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('变更前'), findsOneWidget);

    im.controller.add(
      AppImEvent(
        command: 'edit',
        message: null,
        eventId: 'gap-edit',
        mutation: AppImMessageMutation(
          command: 'edit',
          eventId: 'gap-edit',
          eventType: 'message.edited',
          conversationId: 'conversation-01',
          messageId: 'message-gap',
          messageSeq: 1,
          changeSeq: 2,
          actorOrganization: 1,
          actorUserId: 'user-01',
          targetOrganization: null,
          targetUserId: null,
          scope: '',
          status: '',
          message: _message('message-gap', 1, '不应直接采用的乱序事件', 'user-01'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(messaging.fetchCount, 1);
    expect(find.text('权威刷新结果'), findsOneWidget);

    im.controller.add(
      AppImEvent(
        command: 'edit',
        message: null,
        eventId: 'stale-edit',
        mutation: AppImMessageMutation(
          command: 'edit',
          eventId: 'stale-edit',
          eventType: 'message.edited',
          conversationId: 'conversation-01',
          messageId: 'message-gap',
          messageSeq: 1,
          changeSeq: 1,
          actorOrganization: 1,
          actorUserId: 'user-01',
          targetOrganization: null,
          targetUserId: null,
          scope: '',
          status: '',
          message: _message('message-gap', 1, '过期事件不得覆盖', 'user-01'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('权威刷新结果'), findsOneWidget);
    expect(find.text('过期事件不得覆盖'), findsNothing);
  });

  testWidgets('change_seq gap 刷新失败时保留原消息', (tester) async {
    final im = _FakeImRuntime(
      conversationSync:
          (conversationId, afterMessageSeq, afterChangeSeq) async =>
              throw StateError('authoritative refresh failed'),
    );
    final tenant = tenantFixture();
    final messaging = _GapMessaging(failRefresh: true);
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          messaging: messaging,
          conversation: _singleConversation,
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    im.controller.add(
      AppImEvent(
        command: 'edit',
        message: null,
        eventId: 'failed-gap-edit',
        mutation: AppImMessageMutation(
          command: 'edit',
          eventId: 'failed-gap-edit',
          eventType: 'message.edited',
          conversationId: 'conversation-01',
          messageId: 'message-gap',
          messageSeq: 1,
          changeSeq: 3,
          actorOrganization: 1,
          actorUserId: 'user-01',
          targetOrganization: null,
          targetUserId: null,
          scope: '',
          status: '',
          message: _message('message-gap', 1, '失败时不得覆盖', 'user-01'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('变更前'), findsOneWidget);
    expect(find.text('失败时不得覆盖'), findsNothing);
    expect(find.textContaining('authoritative refresh failed'), findsOneWidget);
  });

  testWidgets('好友事件、resume 与 reconnect 串行合并权威联系人和申请快照', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final contacts = _ToggleContacts(
      contacts: const [_externalContact],
      requests: const [_externalFriendRequest],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          contacts: contacts,
          messaging: _FakeMessaging(),
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(contacts.contactsFetchCount, 1);
    expect(contacts.requestsFetchCount, 1);

    contacts.contactsBarrier = Completer<void>();
    contacts.requestsBarrier = Completer<void>();
    im.controller.add(_friendControlEvent('71'.padLeft(64, '0'), 'accepted'));
    im.controller.add(_friendControlEvent('72'.padLeft(64, '0'), 'created'));
    im.controller.add(_friendControlEvent('73'.padLeft(64, '0'), 'rejected'));
    await tester.pump();
    expect(contacts.contactsFetchCount, 2);
    expect(contacts.requestsFetchCount, 2);

    contacts.contactsBarrier!.complete();
    contacts.requestsBarrier!.complete();
    await tester.pumpAndSettle();
    expect(contacts.contactsFetchCount, 3);
    expect(contacts.requestsFetchCount, 3);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(contacts.contactsFetchCount, 4);
    expect(contacts.requestsFetchCount, 4);

    im.emitConnectionStatus(AppImConnectionStatus.reconnecting);
    im.emitConnectionStatus(AppImConnectionStatus.connected);
    await tester.pumpAndSettle();
    expect(contacts.contactsFetchCount, 5);
    expect(contacts.requestsFetchCount, 5);

    contacts.failFetch = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(contacts.contactsFetchCount, 6);
    expect(contacts.requestsFetchCount, 6);
    expect(find.text('通讯录暂时不可用，请稍后重试'), findsOneWidget);

    contacts.failFetch = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(contacts.contactsFetchCount, 7);
    expect(contacts.requestsFetchCount, 7);
    expect(find.byKey(const ValueKey('contact-2-external-01')), findsOneWidget);
  });

  testWidgets('无会话时跨机构撤权仍即时清除好友与搜索入口', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final session = AppSession(
      accessToken: 'token',
      expireAt: 4102444800,
      organization: 1,
      deploymentId: tenant.deploymentId,
      deviceId: '0123456789abcdef0123456789abcdef',
      runtime: const AppClientRuntime(os: 'ios'),
      user: const AppUser(
        id: '9',
        userId: 'user-01',
        account: 'acceptance',
        nickname: '验收用户',
      ),
    );
    const peer = AppContact(
      id: '20',
      organization: 2,
      organizationName: '外部机构',
      companyName: '外部公司',
      isCrossOrganization: true,
      userId: 'external-01',
      account: 'external',
      nickname: '外部好友',
      signature: '',
      avatarUrl: '',
      mobile: '',
      imShortNo: '20001',
      statusText: '正常',
      remark: '',
      relationStatus: 'friend',
      isSystem: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          tenant: tenant,
          session: session,
          im: im,
          contacts: const _FakeContacts(
            contacts: [peer],
            requests: [
              AppFriendRequest(
                id: 30,
                direction: 'incoming',
                message: '申请添加好友',
                status: 1,
                statusText: '待处理',
                createTime: '2026-07-20 12:00:00',
                fromOrganization: 2,
                toOrganization: 1,
                fromUser: peer,
                toUser: null,
              ),
            ],
          ),
          messaging: _FakeMessaging(),
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('contact-2-external-01')), findsOneWidget);

    im.controller.add(
      const AppImEvent(
        command: 'conversation.access_changed',
        message: null,
        eventId:
            'abababababababababababababababababababababababababababababababab',
        accessChanged: AppImConversationAccessChanged(
          eventId:
              'abababababababababababababababababababababababababababababababab',
          snapshotId: '2',
          conversationId: 'single-cross-without-local-conversation',
          allowed: false,
          targetOrganization: 1,
          targetUserId: 'user-01',
          peerOrganization: 2,
          peerUserId: 'external-01',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('contact-2-external-01')), findsNothing);
  });

  testWidgets('跨机构 access 变化会立即关闭已打开的旧名片页', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final contacts = _ToggleContacts(contacts: const [_externalContact]);
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          contacts: contacts,
          messaging: _FakeMessaging(),
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('contact-2-external-01')));
    await tester.pumpAndSettle();
    expect(find.text('个人名片'), findsOneWidget);

    contacts.failFetch = true;
    im.controller.add(_crossOrgAccessEvent('2', true));
    await tester.pumpAndSettle();

    expect(find.text('个人名片'), findsNothing);
    expect(find.byKey(const ValueKey('contact-2-external-01')), findsNothing);
  });

  testWidgets('联系人恢复 HTTP 失败时旧跨机构条目保持隐藏', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final contacts = _ToggleContacts(contacts: const [_externalContact]);
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          contacts: contacts,
          messaging: _FakeMessaging(),
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('contact-2-external-01')), findsOneWidget);
    im.controller.add(_crossOrgAccessEvent('2', false));
    await tester.pumpAndSettle();
    contacts.failFetch = true;
    im.controller.add(_crossOrgAccessEvent('3', true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('contact-2-external-01')), findsNothing);
    expect(find.text('通讯录暂时不可用，请稍后重试'), findsOneWidget);
    contacts.failFetch = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('contact-2-external-01')), findsOneWidget);
  });

  testWidgets('跨机构好友申请恢复失败时隐藏且 handle 不会发网', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final contacts = _ToggleContacts(
      contacts: const [],
      requests: const [_externalFriendRequest],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: FriendRequestsPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          contacts: contacts,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final menu = tester.widget<PopupMenuButton<bool>>(
      find.byType(PopupMenuButton<bool>),
    );
    final staleHandle = menu.onSelected!;

    im.controller.add(_crossOrgAccessEvent('2', false));
    await tester.pumpAndSettle();
    contacts.failFetch = true;
    im.controller.add(_crossOrgAccessEvent('3', true));
    await tester.pumpAndSettle();

    expect(find.byType(PopupMenuButton<bool>), findsNothing);
    expect(find.text('外部好友 · 外部公司'), findsNothing);
    staleHandle(true);
    await tester.pumpAndSettle();
    expect(contacts.handleCount, 0);
  });

  testWidgets('跨机构恢复的权威 HTTP 失败时会话保持 fail-closed', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    final messaging = _CrossOrgMessaging();
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          messaging: messaging,
          conversation: _crossOrgConversation,
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('message-composer')))
          .enabled,
      isTrue,
    );
    im.controller.add(_crossOrgAccessEvent('2', false));
    await tester.pump();
    messaging.failFetch = true;
    im.controller.add(_crossOrgAccessEvent('3', true));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('message-composer')))
          .enabled,
      isFalse,
    );
    expect(
      find.textContaining('authoritative access refresh failed'),
      findsOneWidget,
    );
    messaging.failFetch = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('message-composer')))
          .enabled,
      isTrue,
    );
  });

  testWidgets('访问 epoch 变化会中止后续 read ACK', (tester) async {
    final ackBarrier = Completer<void>();
    final im = _FakeImRuntime(acknowledgeBarrier: () => ackBarrier.future);
    final tenant = tenantFixture();
    final messaging = _CrossOrgMessaging(messageCount: 2);
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          messaging: messaging,
          conversation: _crossOrgConversation,
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(im.acknowledgements, hasLength(1));
    im.controller.add(_crossOrgAccessEvent('2', false));
    await tester.pump();
    ackBarrier.complete();
    await tester.pumpAndSettle();
    expect(im.acknowledgements, hasLength(1));
    expect(im.conversationReadCount, 0);
    expect(messaging.markReadCount, 0);
  });

  testWidgets('断线状态会立即清除 typing', (tester) async {
    final im = _FakeImRuntime();
    final tenant = tenantFixture();
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationPage(
          tenant: tenant,
          session: _testSession(tenant),
          im: im,
          messaging: _FakeMessaging(),
          conversation: _singleConversation,
          media: _UnusedMedia(),
          mediaPicker: _UnusedMediaPicker(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    im.controller.add(
      const AppImEvent(
        command: 'typing',
        message: null,
        eventId: null,
        typing: AppImTypingState(
          conversationId: 'conversation-01',
          actorOrganization: 1,
          actorUserId: 'peer-01',
          username: '测试好友',
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing-indicator')), findsOneWidget);
    im.controller.add(
      const AppImEvent(
        command: 'connection_status',
        message: null,
        eventId: null,
        connectionStatus: AppImConnectionStatus.reconnecting,
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing-indicator')), findsNothing);
    im.controller.add(
      const AppImEvent(
        command: 'typing',
        message: null,
        eventId: null,
        typing: AppImTypingState(
          conversationId: 'conversation-01',
          actorOrganization: 1,
          actorUserId: 'peer-01',
          username: '测试好友',
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('typing-indicator')), findsNothing);
  });
}
