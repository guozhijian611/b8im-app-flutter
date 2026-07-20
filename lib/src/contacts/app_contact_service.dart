import '../discovery/tenant_config.dart';
import '../network/app_api_client.dart';
import '../session/app_session.dart';
import 'app_contact_models.dart';

abstract interface class AppContactGateway {
  Future<List<AppContact>> fetchContacts({
    required TenantConfig tenant,
    required AppSession session,
    String keyword = '',
  });

  Future<List<AppFriendRequest>> fetchFriendRequests({
    required TenantConfig tenant,
    required AppSession session,
  });

  Future<List<AppContact>> searchUsers({
    required TenantConfig tenant,
    required AppSession session,
    required String keyword,
  });

  Future<String> sendFriendRequest({
    required TenantConfig tenant,
    required AppSession session,
    required int organization,
    required String userId,
    required String message,
  });

  Future<void> handleFriendRequest({
    required TenantConfig tenant,
    required AppSession session,
    required AppFriendRequest request,
    required bool accept,
  });
}

final class AppContactService implements AppContactGateway {
  const AppContactService(this.api);

  final AppApiClient api;

  @override
  Future<List<AppContact>> fetchContacts({
    required TenantConfig tenant,
    required AppSession session,
    String keyword = '',
  }) async {
    final data = await api.request(
      tenant,
      '/saimulti/app/im/contacts',
      accessToken: session.accessToken,
      query: {if (keyword.trim().isNotEmpty) 'keyword': keyword.trim()},
    );
    return _contacts(data, 'contacts');
  }

  @override
  Future<List<AppFriendRequest>> fetchFriendRequests({
    required TenantConfig tenant,
    required AppSession session,
  }) async {
    final data = await api.request(
      tenant,
      '/saimulti/app/im/requests',
      accessToken: session.accessToken,
    );
    if (data is! List) throw const FormatException('好友申请响应格式无效');
    return data.map(AppFriendRequest.fromJson).toList(growable: false);
  }

  @override
  Future<List<AppContact>> searchUsers({
    required TenantConfig tenant,
    required AppSession session,
    required String keyword,
  }) async {
    final value = keyword.trim();
    if (value.isEmpty) return const [];
    final data = await api.request(
      tenant,
      '/saimulti/app/im/searchUsers',
      accessToken: session.accessToken,
      query: {'keyword': value},
    );
    return _contacts(data, 'searchUsers');
  }

  @override
  Future<String> sendFriendRequest({
    required TenantConfig tenant,
    required AppSession session,
    required int organization,
    required String userId,
    required String message,
  }) async {
    final targetUserId = userId.trim();
    if (organization <= 0 || targetUserId.isEmpty) {
      throw const FormatException('好友申请缺少目标复合身份');
    }
    final data = contactMap(
      await api.request(
        tenant,
        '/saimulti/app/im/sendFriendRequest',
        method: AppApiMethod.post,
        accessToken: session.accessToken,
        body: {
          'to_organization': organization,
          'to_user_id': targetUserId,
          'message': message.trim(),
        },
      ),
      'sendFriendRequest',
    );
    return contactString(data['message'], fallback: '好友申请已发送');
  }

  @override
  Future<void> handleFriendRequest({
    required TenantConfig tenant,
    required AppSession session,
    required AppFriendRequest request,
    required bool accept,
  }) async {
    if (!request.isPendingIncoming ||
        !request.hasAuthoritativeContext(session.organization)) {
      throw const FormatException('好友申请缺少当前机构复合上下文');
    }
    await api.request(
      tenant,
      '/saimulti/app/im/handleFriendRequest',
      method: AppApiMethod.post,
      accessToken: session.accessToken,
      body: {
        'id': request.id,
        'action': accept ? 'accept' : 'reject',
        'from_organization': request.fromOrganization,
        'to_organization': request.toOrganization,
      },
    );
  }

  static List<AppContact> _contacts(Object? data, String field) {
    if (data is! List) throw FormatException('$field 响应格式无效');
    return data
        .map((item) => AppContact.fromJson(item, field: field))
        .toList(growable: false);
  }
}
