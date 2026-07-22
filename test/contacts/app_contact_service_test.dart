import 'dart:convert';

import 'package:b8im_app_flutter/src/contacts/app_contact_models.dart';
import 'package:b8im_app_flutter/src/contacts/app_contact_service.dart';
import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/tenant_fixture.dart';

void main() {
  test('App 通讯录、好友申请和用户搜索使用 App 专用接口', () async {
    final requests = <http.Request>[];
    final api = AppApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        final user = {
          'id': 2,
          'organization': 2,
          'organization_name': '外部机构',
          'company_name': '外部公司',
          'is_cross_organization': true,
          'user_id': 'peer-01',
          'account': 'peer',
          'nickname': '测试好友',
          'signature': '产品部',
          'avatar_url': '',
          'mobile': '',
          'im_short_no': '10002',
          'status_text': '正常',
          'remark': '',
          'relation_status': 'friend',
          'is_system': false,
        };
        return switch (request.url.path) {
          '/saimulti/app/im/contacts' => _response([user]),
          '/saimulti/app/im/requests' => _response([
            {
              'id': 7,
              'direction': 'incoming',
              'message': '申请添加好友',
              'status': 1,
              'status_text': '待处理',
              'create_time': '2026-07-17 10:00:00',
              'handle_time': '',
              'from_organization': 2,
              'to_organization': 1,
              'from_user': user,
              'to_user': null,
            },
          ]),
          '/saimulti/app/im/searchUsers' => _response([user]),
          '/saimulti/app/im/sendFriendRequest' => _response({
            'status': 'pending',
            'message': '好友申请已发送',
          }),
          '/saimulti/app/im/handleFriendRequest' => _response({
            'status': 'accepted',
          }),
          _ => http.Response('not found', 404),
        };
      }),
    );
    final service = AppContactService(api);
    final tenant = tenantFixture();
    final session = _session();

    final contacts = await service.fetchContacts(
      tenant: tenant,
      session: session,
    );
    final friendRequests = await service.fetchFriendRequests(
      tenant: tenant,
      session: session,
    );
    final users = await service.searchUsers(
      tenant: tenant,
      session: session,
      keyword: '测试',
    );
    final message = await service.sendFriendRequest(
      tenant: tenant,
      session: session,
      organization: 2,
      userId: 'peer-01',
      message: '我是验收用户',
    );
    await service.handleFriendRequest(
      tenant: tenant,
      session: session,
      request: friendRequests.single,
      accept: true,
    );
    await expectLater(
      service.handleFriendRequest(
        tenant: tenant,
        session: session,
        request: AppFriendRequest(
          id: 8,
          direction: 'incoming',
          message: '',
          status: 1,
          statusText: '待处理',
          createTime: '',
          fromOrganization: 2,
          toOrganization: 99,
          fromUser: friendRequests.single.fromUser,
          toUser: null,
        ),
        accept: true,
      ),
      throwsA(isA<FormatException>()),
    );

    expect(contacts.single.displayName, '测试好友 · 外部公司');
    expect(friendRequests.single.isPendingIncoming, isTrue);
    expect(users.single.userId, 'peer-01');
    expect(message, '好友申请已发送');
    expect(requests, hasLength(5));
    for (final request in requests) {
      expect(request.headers['app-id'], '1');
      expect(request.headers['authorization'], 'Bearer access-token');
      expect(request.url.path, startsWith('/saimulti/app/im/'));
    }
    expect(requests[2].url.queryParameters['keyword'], '测试');
    expect(jsonDecode(requests[3].body)['to_user_id'], 'peer-01');
    expect(jsonDecode(requests[3].body)['to_organization'], 2);
    expect(jsonDecode(requests[4].body), {
      'id': 7,
      'action': 'accept',
      'from_organization': 2,
      'to_organization': 1,
    });
    api.close();
  });

  test('好友申请缺少顶层机构或用户机构不一致时 fail-closed', () {
    expect(
      () => AppFriendRequest.fromJson({
        'id': 7,
        'direction': 'incoming',
        'status': 1,
        'from_user': null,
        'to_user': null,
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => AppFriendRequest.fromJson({
        'id': 7,
        'direction': 'incoming',
        'status': 1,
        'from_organization': 3,
        'to_organization': 1,
        'from_user': {'organization': 2, 'user_id': 'peer-01'},
        'to_user': null,
      }),
      throwsA(isA<FormatException>()),
    );
  });
}

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

http.Response _response(Object? data) => http.Response(
  jsonEncode({'code': 200, 'message': 'success', 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);
