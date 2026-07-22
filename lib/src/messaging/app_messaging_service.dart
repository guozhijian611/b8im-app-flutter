import '../discovery/tenant_config.dart';
import '../network/app_api_client.dart';
import '../im/group_member_access.dart';
import '../session/app_session.dart';
import 'app_im_models.dart';

abstract interface class AppMessagingGateway {
  Future<List<AppImConversation>> fetchConversations({
    required TenantConfig tenant,
    required AppSession session,
  });

  Future<AppImMessagePage> fetchMessages({
    required TenantConfig tenant,
    required AppSession session,
    required int conversationType,
    required String conversationId,
    int peerOrganization = 0,
    String peerUserId = '',
    int beforeSeq = 0,
    int limit = 50,
  });

  Future<int> markRead({
    required TenantConfig tenant,
    required AppSession session,
    required int conversationType,
    required String conversationId,
  });
}

final class AppMessagingService implements AppMessagingGateway {
  AppMessagingService(this.api);

  final AppApiClient api;

  @override
  Future<List<AppImConversation>> fetchConversations({
    required TenantConfig tenant,
    required AppSession session,
  }) async {
    final groupAccess = GroupMemberAccessRegistry.lookup(
      session.organization,
      session.user.userId,
    );
    if (groupAccess == null) {
      throw StateError('群成员访问快照尚未初始化');
    }
    final epoch = groupAccess.captureEpoch();
    final data = await api.request(
      tenant,
      '/saimulti/app/im/conversations',
      accessToken: session.accessToken,
    );
    if (data is! List) {
      throw const FormatException('会话列表响应格式无效');
    }
    final conversations = data
        .map(AppImConversation.fromJson)
        .where(
          (conversation) =>
              conversation.conversationType != 2 ||
              groupAccess.entry(conversation.conversationId) != null,
        )
        .toList(growable: false);
    epoch.assertCurrent();
    return conversations;
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
    if (conversationType != 1 && conversationType != 2) {
      throw const FormatException('消息分页 conversation_type 无效');
    }
    final groupAccess = conversationType == 2
        ? GroupMemberAccessRegistry.lookup(
            session.organization,
            session.user.userId,
          )
        : null;
    if (conversationType == 2 && groupAccess == null) {
      throw StateError('群成员访问快照尚未初始化');
    }
    final entry = conversationType == 2
        ? groupAccess!.assertVisible(conversationId)
        : null;
    final epoch = conversationType == 2 ? groupAccess!.captureEpoch() : null;
    final normalizedConversationId = conversationId.trim();
    final normalizedPeerUserId = peerUserId.trim();
    if ((normalizedConversationId.isEmpty &&
            (peerOrganization <= 0 || normalizedPeerUserId.isEmpty)) ||
        (normalizedConversationId.isNotEmpty &&
            (peerOrganization > 0 || normalizedPeerUserId.isNotEmpty)) ||
        beforeSeq < 0) {
      throw const FormatException('消息分页参数无效');
    }
    final data = await api.request(
      tenant,
      '/saimulti/app/im/messages',
      accessToken: session.accessToken,
      query: {
        if (normalizedConversationId.isNotEmpty)
          'conversation_id': normalizedConversationId,
        if (normalizedPeerUserId.isNotEmpty)
          'peer_organization': peerOrganization.toString(),
        if (normalizedPeerUserId.isNotEmpty)
          'peer_user_id': normalizedPeerUserId,
        'conversation_type': conversationType.toString(),
        'before_seq': beforeSeq.toString(),
        'after_seq': '0',
        'limit': limit.clamp(1, 100).toString(),
      },
    );
    final page = AppImMessagePage.fromJson(data, session.organization);
    epoch?.assertCurrent();
    if (entry != null &&
        page.messages.any(
          (message) =>
              message.conversationId != normalizedConversationId ||
              !entry.containsMessageSequence(message.messageSeq),
        )) {
      throw const FormatException('消息分页包含群访问周期外数据');
    }
    return page;
  }

  @override
  Future<int> markRead({
    required TenantConfig tenant,
    required AppSession session,
    required int conversationType,
    required String conversationId,
  }) async {
    if (conversationType != 1 && conversationType != 2) {
      throw const FormatException('markRead conversation_type 无效');
    }
    final groupAccess = conversationType == 2
        ? GroupMemberAccessRegistry.lookup(
            session.organization,
            session.user.userId,
          )
        : null;
    if (conversationType == 2 && groupAccess == null) {
      throw StateError('群成员访问快照尚未初始化');
    }
    final entry = conversationType == 2
        ? groupAccess!.assertVisible(conversationId)
        : null;
    if (entry != null && !entry.isActive) {
      throw StateError('history_only 群会话禁止推进已读');
    }
    final epoch = conversationType == 2 ? groupAccess!.captureEpoch() : null;
    final data = imMap(
      await api.request(
        tenant,
        '/saimulti/app/im/markRead',
        method: AppApiMethod.post,
        accessToken: session.accessToken,
        body: {
          'conversation_id': conversationId,
          'conversation_type': conversationType,
          'all': false,
        },
      ),
      'markRead',
    );
    final updated = imInt(data, 'updated', 'markRead.updated');
    epoch?.assertCurrent();
    if (updated < 0) throw const FormatException('markRead.updated 无效');
    return updated;
  }
}
