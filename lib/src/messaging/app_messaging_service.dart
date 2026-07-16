import '../discovery/tenant_config.dart';
import '../network/app_api_client.dart';
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
    required String conversationId,
    int beforeSeq = 0,
    int limit = 50,
  });

  Future<int> markRead({
    required TenantConfig tenant,
    required AppSession session,
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
    final data = await api.request(
      tenant,
      '/saimulti/app/im/conversations',
      accessToken: session.accessToken,
    );
    if (data is! List) {
      throw const FormatException('会话列表响应格式无效');
    }
    return data.map(AppImConversation.fromJson).toList(growable: false);
  }

  @override
  Future<AppImMessagePage> fetchMessages({
    required TenantConfig tenant,
    required AppSession session,
    required String conversationId,
    int beforeSeq = 0,
    int limit = 50,
  }) async {
    if (conversationId.trim().isEmpty || beforeSeq < 0) {
      throw const FormatException('消息分页参数无效');
    }
    final data = await api.request(
      tenant,
      '/saimulti/app/im/messages',
      accessToken: session.accessToken,
      query: {
        'conversation_id': conversationId.trim(),
        'before_seq': beforeSeq.toString(),
        'after_seq': '0',
        'limit': limit.clamp(1, 100).toString(),
      },
    );
    return AppImMessagePage.fromJson(data, session.organization);
  }

  @override
  Future<int> markRead({
    required TenantConfig tenant,
    required AppSession session,
    required String conversationId,
  }) async {
    final data = imMap(
      await api.request(
        tenant,
        '/saimulti/app/im/markRead',
        method: AppApiMethod.post,
        accessToken: session.accessToken,
        body: {'conversation_id': conversationId, 'all': false},
      ),
      'markRead',
    );
    final updated = imInt(data, 'updated', 'markRead.updated');
    if (updated < 0) throw const FormatException('markRead.updated 无效');
    return updated;
  }
}
