import 'dart:convert';
import 'dart:async';

import 'package:b8im_app_flutter/src/im/group_member_access.dart';
import 'package:b8im_app_flutter/src/messaging/app_im_models.dart';
import 'package:b8im_app_flutter/src/messaging/app_messaging_service.dart';
import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/tenant_fixture.dart';

void main() {
  late GroupMemberAccessRegistry groupAccess;
  setUp(() async {
    groupAccess = GroupMemberAccessRegistry(organization: 1, userId: 'user-01');
    await groupAccess.replace(
      GroupMemberAccessSnapshot(snapshotId: '1', entries: const {}),
    );
  });

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
            expect(request.url.queryParameters['conversation_type'], '1');
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
              'conversation_type': 1,
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
      conversationType: 1,
      conversationId: 'conversation-01',
      beforeSeq: 9,
    );
    final updated = await service.markRead(
      tenant: tenant,
      session: session,
      conversationType: 1,
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

  test('群历史空页也受 entry 与请求期 epoch 门禁', () async {
    final requestStarted = Completer<void>();
    final releaseResponse = Completer<void>();
    var requestCount = 0;
    final api = AppApiClient(
      httpClient: MockClient((request) async {
        requestCount += 1;
        requestStarted.complete();
        await releaseResponse.future;
        return _response({
          'messages': const [],
          'next_after_seq': 0,
          'next_before_seq': 0,
          'has_more_before': false,
        });
      }),
    );
    final service = AppMessagingService(api);
    final session = _session();

    await expectLater(
      service.fetchMessages(
        tenant: tenantFixture(),
        session: session,
        conversationType: 2,
        conversationId: 'group-1',
      ),
      throwsStateError,
    );
    expect(requestCount, 0);

    groupAccess.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '2',
        entries: {'group-1': _groupEntry(state: 'active', toSeq: null)},
      ),
    );
    final pending = service.fetchMessages(
      tenant: tenantFixture(),
      session: session,
      conversationType: 2,
      conversationId: 'group-1',
    );
    await requestStarted.future;
    groupAccess.failClose();
    releaseResponse.complete();
    await expectLater(pending, throwsStateError);

    groupAccess.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '3',
        entries: {
          'group-1': _groupEntry(
            state: 'history_only',
            toSeq: '10',
            accessVersion: '2',
          ),
        },
      ),
    );
    await expectLater(
      service.markRead(
        tenant: tenantFixture(),
        session: session,
        conversationType: 2,
        conversationId: 'group-1',
      ),
      throwsStateError,
    );
    expect(requestCount, 1);
    api.close();
  });

  test('群 markRead HTTP 在响应交错中失效时不返回成功', () async {
    groupAccess.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '5',
        entries: {'group-1': _groupEntry(state: 'active', toSeq: null)},
      ),
    );
    final requestStarted = Completer<void>();
    final response = Completer<http.Response>();
    final api = AppApiClient(
      httpClient: MockClient((request) {
        expect(request.url.path, '/saimulti/app/im/markRead');
        requestStarted.complete();
        return response.future;
      }),
    );
    final service = AppMessagingService(api);

    final pending = service.markRead(
      tenant: tenantFixture(),
      session: _session(),
      conversationType: 2,
      conversationId: 'group-1',
    );
    await requestStarted.future;
    groupAccess.failClose();
    response.complete(_response({'updated': 1}));

    await expectLater(pending, throwsStateError);
    await groupAccess.replace(
      GroupMemberAccessSnapshot(snapshotId: '6', entries: const {}),
    );
    api.close();
  });

  test('history_only HTTP 历史只接受 periods 覆盖的消息', () async {
    groupAccess.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '4',
        entries: {
          'group-1': GroupMemberAccessEntry.fromJson({
            'conversation_id': 'group-1',
            'conversation_type': 2,
            'access_version': '2',
            'access_state': 'history_only',
            'last_message_seq': '10',
            'last_change_seq': '1',
            'periods': [
              {'period_no': '1', 'from_seq': '1', 'to_seq': '5'},
            ],
          }),
        },
      ),
    );
    var includeOutsideMessage = false;
    final api = AppApiClient(
      httpClient: MockClient((request) async {
        expect(request.url.queryParameters['conversation_type'], '2');
        return _response({
          'messages': includeOutsideMessage
              ? [
                  {
                    'id': 6,
                    'organization': 1,
                    'conversation_id': 'group-1',
                    'conversation_type': 2,
                    'message_id': 'message-6',
                    'message_seq': 6,
                    'client_msg_id': 'client-6',
                    'sender_organization': 1,
                    'sender_id': 'member-2',
                    'sender_user': null,
                    'message_type': 1,
                    'content': {'text': 'outside'},
                    'status': 1,
                    'delivery_status': null,
                    'edit_time': '',
                    'edit_count': 0,
                    'create_time': '2026-07-20 12:00:00',
                  },
                ]
              : const [],
          'next_after_seq': 0,
          'next_before_seq': 0,
          'has_more_before': false,
        });
      }),
    );
    final service = AppMessagingService(api);
    final empty = await service.fetchMessages(
      tenant: tenantFixture(),
      session: _session(),
      conversationType: 2,
      conversationId: 'group-1',
    );
    expect(empty.messages, isEmpty);
    includeOutsideMessage = true;
    await expectLater(
      service.fetchMessages(
        tenant: tenantFixture(),
        session: _session(),
        conversationType: 2,
        conversationId: 'group-1',
      ),
      throwsFormatException,
    );
    api.close();
  });
}

GroupMemberAccessEntry _groupEntry({
  required String state,
  required String? toSeq,
  String accessVersion = '1',
}) => GroupMemberAccessEntry.fromJson({
  'conversation_id': 'group-1',
  'conversation_type': 2,
  'access_version': accessVersion,
  'access_state': state,
  'last_message_seq': '10',
  'last_change_seq': '1',
  'periods': [
    {'period_no': '1', 'from_seq': '1', 'to_seq': toSeq},
  ],
});

http.Response _response(Object? data) => http.Response(
  jsonEncode({'code': 200, 'message': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);

AppSession _session() => const AppSession(
  accessToken: 'access-token',
  expireAt: 4102444800,
  organization: 1,
  deploymentId: 'b8im-test',
  deviceId: 'device-01',
  runtime: AppClientRuntime(os: 'ios'),
  user: AppUser(
    id: '9',
    userId: 'user-01',
    account: 'acceptance',
    nickname: '验收用户',
  ),
);
