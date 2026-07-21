import 'dart:async';
import 'dart:convert';

import 'package:b8im_app_flutter/src/im/group_member_access.dart';
import 'package:b8im_app_flutter/src/modules/app_module_api.dart';
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

  test('App 消息搜索保留同名用户的机构维度并显示复合身份', () async {
    final requests = <http.Request>[];
    final api = AppApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        return _searchResponse([
          _row(901, 'same-user', 'message-1'),
          _row(902, 'same-user', 'message-2'),
        ]);
      }),
    );
    final service = AppModuleApiService(
      tenant: tenantFixture(),
      session: _session(),
      apiClient: api,
    );

    final hits = await service.searchMessages(' same ');

    expect(hits, hasLength(2));
    expect(hits.map((item) => item.senderUserId), ['same-user', 'same-user']);
    expect(hits.map((item) => item.senderOrganization), [901, 902]);
    expect(hits.map((item) => item.messageSeq), ['1', '1']);
    expect(hits.map((item) => item.senderIdentityLabel), [
      '机构 901 · same-user',
      '机构 902 · same-user',
    ]);
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/saimulti/app/search/messages');
    expect(requests.single.url.queryParameters, {
      'q': 'same',
      'page': '1',
      'limit': '50',
    });
    api.close();
  });

  test('App 消息搜索可选发送人筛选只序列化完整复合身份', () async {
    final requests = <http.Request>[];
    final api = AppApiClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        return _searchResponse([_row(902, 'same-user', 'message-2')]);
      }),
    );
    final service = AppModuleApiService(
      tenant: tenantFixture(),
      session: _session(),
      apiClient: api,
    );
    final filter = SearchMessageSenderFilter(
      senderOrganization: 902,
      senderUserId: 'same-user',
    );

    final hits = await service.searchMessages(' same ', sender: filter);

    expect(hits.single.senderIdentityLabel, '机构 902 · same-user');
    expect(requests.single.url.queryParameters, {
      'q': 'same',
      'page': '1',
      'limit': '50',
      'sender_organization': '902',
      'sender_user_id': 'same-user',
    });
    api.close();
  });

  test('App 消息搜索发送人筛选模型拒绝非法复合身份', () {
    for (final organization in [0, -1, 9007199254740992]) {
      expect(
        () => SearchMessageSenderFilter(
          senderOrganization: organization,
          senderUserId: 'sender',
        ),
        throwsFormatException,
        reason: '$organization',
      );
    }
    for (final userId in [
      '',
      ' sender',
      'sender ',
      'bad|id',
      'bad\u0000id',
      'bad\u0009id',
      'bad\u000Aid',
      'bad\u000Bid',
      'bad\u000Did',
      '界' * 22,
      'x' * 65,
    ]) {
      expect(
        () => SearchMessageSenderFilter(
          senderOrganization: 901,
          senderUserId: userId,
        ),
        throwsFormatException,
        reason: userId,
      );
    }
    expect(
      SearchMessageSenderFilter(
        senderOrganization: 901,
        senderUserId: '界' * 21,
      ).senderUserId,
      '界' * 21,
    );
    for (final userId in ['\u000Cidentity\u000C', '\u00A0identity\u00A0']) {
      expect(
        SearchMessageSenderFilter(
          senderOrganization: 901,
          senderUserId: userId,
        ).senderUserId,
        userId,
      );
    }
  });

  test('App 消息搜索缺少或伪造 sender_organization 时失败关闭', () async {
    for (final organization in <Object?>[null, 0, -1, 1.5, '901']) {
      final api = AppApiClient(
        httpClient: MockClient(
          (_) async => _searchResponse([
            _row(organization, 'sender', 'message-invalid'),
          ]),
        ),
      );
      final service = AppModuleApiService(
        tenant: tenantFixture(),
        session: _session(),
        apiClient: api,
      );

      await expectLater(
        service.searchMessages('hello'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('sender_organization'),
          ),
        ),
        reason: '$organization',
      );
      api.close();
    }
  });

  test('App 消息搜索只接受 canonical 非空 sender_user_id', () async {
    for (final userId in <Object?>[
      null,
      '',
      ' sender',
      'sender ',
      7,
      'bad|id',
      'bad\u0000id',
      'bad\u0009id',
      'bad\u000Aid',
      'bad\u000Bid',
      'bad\u000Did',
      '界' * 22,
      'x' * 65,
    ]) {
      final api = AppApiClient(
        httpClient: MockClient(
          (_) async => _searchResponse([_row(901, userId, 'message-invalid')]),
        ),
      );
      final service = AppModuleApiService(
        tenant: tenantFixture(),
        session: _session(),
        apiClient: api,
      );

      await expectLater(
        service.searchMessages('hello'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('sender_user_id'),
          ),
        ),
        reason: '$userId',
      );
      api.close();
    }
  });

  test('App 消息搜索固定 DTO 的其余字段缺失或类型错误时失败关闭', () async {
    for (final field in [
      'message_id',
      'conversation_id',
      'conversation_type',
      'sender_organization',
      'sender_user_id',
      'message_type',
      'message_seq',
      'content',
      'sent_at',
    ]) {
      final missing = _row(901, 'sender', 'message-1')..remove(field);
      await _expectInvalidRow(missing, field);
    }

    final invalidIds = <Object?>[
      null,
      '',
      ' id',
      'id ',
      7,
      'bad|id',
      'bad\u0000id',
      'x' * 65,
    ];
    final invalidPositiveIntegers = <Object?>[
      null,
      0,
      -1,
      1.5,
      '1',
      9007199254740992,
    ];
    final cases = <String, List<Object?>>{
      'message_id': invalidIds,
      'conversation_id': invalidIds,
      'conversation_type': [null, 0, 3, '2'],
      'message_type': invalidPositiveIntegers,
      'message_seq': [null, 0, 1, '0', '01', '18446744073709551616'],
      'content': [null, 7, <String, Object?>{}],
      'sent_at': ['', '   ', 7, <String, Object?>{}],
    };
    for (final entry in cases.entries) {
      for (final value in entry.value) {
        await _expectInvalidRow({
          ..._row(901, 'sender', 'message-1'),
          entry.key: value,
        }, entry.key);
      }
    }

    final api = AppApiClient(
      httpClient: MockClient(
        (_) async => _searchResponse([
          {..._row(901, 'sender', 'message-null-time'), 'sent_at': null},
          {..._row(901, 'sender', 'message-empty-content'), 'content': ''},
        ]),
      ),
    );
    final service = AppModuleApiService(
      tenant: tenantFixture(),
      session: _session(),
      apiClient: api,
    );
    final valid = await service.searchMessages('hello');
    expect(valid.first.sentAt, isNull);
    expect(valid.last.content, isEmpty);
    api.close();
  });

  test('搜索群命中必须存在访问 entry 且整批位于授权周期', () async {
    final api = AppApiClient(
      httpClient: MockClient(
        (_) async => _searchResponse([
          _row(901, 'sender', 'single-result'),
          {
            ..._row(901, 'sender', 'revoked-group-result'),
            'conversation_id': 'group-1',
            'conversation_type': 2,
            'message_seq': '3',
          },
        ]),
      ),
    );
    final service = AppModuleApiService(
      tenant: tenantFixture(),
      session: _session(),
      apiClient: api,
    );
    await expectLater(service.searchMessages('hello'), throwsFormatException);

    groupAccess.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '2',
        entries: {
          'group-1': GroupMemberAccessEntry.fromJson({
            'conversation_id': 'group-1',
            'conversation_type': 2,
            'access_version': '1',
            'access_state': 'history_only',
            'last_message_seq': '10',
            'last_change_seq': '1',
            'periods': [
              {'period_no': '1', 'from_seq': '2', 'to_seq': '5'},
            ],
          }),
        },
      ),
    );
    final hits = await service.searchMessages('hello');
    expect(hits, hasLength(2));
    expect(hits.last.conversationType, 2);
    api.close();
  });

  test('群搜索 HTTP 在响应交错中失效时丢弃整批结果', () async {
    groupAccess.replace(
      GroupMemberAccessSnapshot(
        snapshotId: '3',
        entries: {
          'group-1': GroupMemberAccessEntry.fromJson({
            'conversation_id': 'group-1',
            'conversation_type': 2,
            'access_version': '3',
            'access_state': 'active',
            'last_message_seq': '10',
            'last_change_seq': '1',
            'periods': [
              {'period_no': '1', 'from_seq': '1', 'to_seq': null},
            ],
          }),
        },
      ),
    );
    final requestStarted = Completer<void>();
    final response = Completer<http.Response>();
    final api = AppApiClient(
      httpClient: MockClient((_) {
        requestStarted.complete();
        return response.future;
      }),
    );
    final service = AppModuleApiService(
      tenant: tenantFixture(),
      session: _session(),
      apiClient: api,
    );

    final pending = service.searchMessages('group secret');
    await requestStarted.future;
    groupAccess.failClose();
    response.complete(
      _searchResponse([
        {
          ..._row(901, 'sender', 'group-result'),
          'conversation_id': 'group-1',
          'conversation_type': 2,
          'message_seq': '3',
        },
      ]),
    );

    await expectLater(pending, throwsStateError);
    await groupAccess.replace(
      GroupMemberAccessSnapshot(snapshotId: '4', entries: const {}),
    );
    api.close();
  });
}

Map<String, Object?> _row(
  Object? senderOrganization,
  Object? senderUserId,
  String messageId,
) => {
  'message_id': messageId,
  'conversation_id': 'conversation-1',
  'conversation_type': 1,
  'sender_organization': senderOrganization,
  'sender_user_id': senderUserId,
  'message_type': 1,
  'message_seq': '1',
  'content': 'hello',
  'sent_at': '2026-07-20 12:00:00',
};

Future<void> _expectInvalidRow(Map<String, Object?> row, String field) async {
  final api = AppApiClient(
    httpClient: MockClient((_) async => _searchResponse([row])),
  );
  final service = AppModuleApiService(
    tenant: tenantFixture(),
    session: _session(),
    apiClient: api,
  );
  try {
    await expectLater(
      service.searchMessages('hello'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains(field),
        ),
      ),
    );
  } finally {
    api.close();
  }
}

http.Response _searchResponse(List<Map<String, Object?>> rows) => http.Response(
  jsonEncode({
    'code': 200,
    'message': 'success',
    'data': {
      'current_page': 1,
      'per_page': 50,
      'total': rows.length,
      'data': rows,
    },
  }),
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
