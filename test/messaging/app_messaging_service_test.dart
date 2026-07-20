import 'dart:convert';

import 'package:b8im_app_flutter/src/messaging/app_im_models.dart';
import 'package:b8im_app_flutter/src/messaging/app_messaging_service.dart';
import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/tenant_fixture.dart';

void main() {
  test('App 会话、消息分页和已读请求使用 App 专用 API', () async {
    final requests = <http.Request>[];
    final api = AppApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        switch (request.url.path) {
          case '/saimulti/app/im/conversations':
            return _response([
              {
                'conversation_id': 'conversation-01',
                'conversation_type': 1,
                'title': '测试好友',
                'peer_user': {
                  'user_id': 'peer-01',
                  'account': 'peer',
                  'nickname': '测试好友',
                  'avatar_url': '',
                  'organization': 1,
                  'company_name': 'b8im 测试机构',
                  'organization_name': 'b8im 测试机构',
                  'is_cross_organization': false,
                  'display_name': '测试好友',
                },
                'last_message_id': 'message-01',
                'last_message_seq': 1,
                'last_message_summary': 'hello',
                'last_message_time': '2026-07-16 21:00:00',
                'unread_count': 1,
                'is_pinned': false,
                'is_muted': false,
                'avatar_url': '',
              },
            ]);
          case '/saimulti/app/im/messages':
            expect(
              request.url.queryParameters['conversation_id'],
              'conversation-01',
            );
            expect(request.url.queryParameters['before_seq'], '9');
            return _response({
              'messages': [
                {
                  'id': 1,
                  'organization': 1,
                  'conversation_id': 'conversation-01',
                  'conversation_type': 1,
                  'message_id': 'message-01',
                  'message_seq': 1,
                  'client_msg_id': 'client-01',
                  'sender_organization': 1,
                  'sender_id': 'user-01',
                  'sender_user': null,
                  'message_type': 1,
                  'content': {'text': 'hello'},
                  'status': 1,
                  'delivery_status': 'read',
                  'edit_time': '',
                  'edit_count': 0,
                  'create_time': '2026-07-16 21:00:00',
                },
              ],
              'next_after_seq': 1,
              'next_before_seq': 1,
              'has_more_before': false,
            });
          case '/saimulti/app/im/markRead':
            expect(jsonDecode(request.body), {
              'conversation_id': 'conversation-01',
              'all': false,
            });
            return _response({'updated': 1});
        }
        return http.Response('not found', 404);
      }),
    );
    final service = AppMessagingService(api);
    final tenant = tenantFixture();
    final session = AppSession(
      accessToken: 'access-token',
      expireAt: 4102444800,
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

    final conversations = await service.fetchConversations(
      tenant: tenant,
      session: session,
    );
    final messages = await service.fetchMessages(
      tenant: tenant,
      session: session,
      conversationId: 'conversation-01',
      beforeSeq: 9,
    );
    final updated = await service.markRead(
      tenant: tenant,
      session: session,
      conversationId: 'conversation-01',
    );

    expect(conversations.single.peerUser?.userId, 'peer-01');
    expect(messages.messages.single.displayText, 'hello');
    expect(messages.messages.single.globalSeq, isNull);
    expect(messages.messages.single.deliveryStatus, AppImDeliveryStatus.read);
    expect(updated, 1);
    expect(requests, hasLength(3));
    for (final request in requests) {
      expect(request.headers['app-id'], '1');
      expect(request.headers['authorization'], 'Bearer access-token');
    }
    api.close();
  });
}

http.Response _response(Object? data) => http.Response(
  jsonEncode({'code': 200, 'message': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);
