import 'dart:async';
import 'dart:convert';

import 'package:b8im_app_flutter/src/im/group_member_access.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('群访问快照只在连续末页后原子提交', () {
    final staging = GroupMemberAccessSnapshotStaging(
      organization: 1,
      minimumSnapshotId: '42',
      limit: 2,
    );

    expect(staging.request('page-1'), {
      'cmd': groupMemberAccessSnapshotCommand,
      'client_msg_id': 'page-1',
      'data': {'access_snapshot_id': null, 'cursor': null, 'limit': 2},
    });
    staging.accept({
      'cmd': groupMemberAccessSnapshotAckCommand,
      'organization': 1,
      'client_msg_id': 'page-1',
      'data': {
        'access_snapshot_id': '42',
        'entries': [
          _entry(
            conversationId: 'group-a',
            state: 'history_only',
            periods: [
              {'period_no': '1', 'from_seq': '10', 'to_seq': '20'},
            ],
          ),
        ],
        'next_cursor': 'opaque-next',
        'has_more': true,
      },
    });

    expect(staging.committed, throwsStateError);
    expect(staging.request('page-2'), {
      'cmd': groupMemberAccessSnapshotCommand,
      'client_msg_id': 'page-2',
      'data': {'access_snapshot_id': '42', 'cursor': 'opaque-next', 'limit': 2},
    });
    staging.accept({
      'cmd': groupMemberAccessSnapshotAckCommand,
      'organization': 1,
      'client_msg_id': 'page-2',
      'data': {
        'access_snapshot_id': '42',
        'entries': [_entry(conversationId: 'group-b')],
        'next_cursor': null,
        'has_more': false,
      },
    });

    final committed = staging.committed();
    expect(committed.snapshotId, '42');
    expect(committed.entries.keys, ['group-a', 'group-b']);
    expect(committed.entries['group-a']!.isHistoryOnly, isTrue);
    expect(committed.entries['group-b']!.isActive, isTrue);
  });

  test('群访问 uint64、周期与分页顺序按固定 schema 失败关闭', () {
    expect(
      normalizeGroupAccessPositiveDecimal('18446744073709551616'),
      isEmpty,
    );
    expect(normalizeGroupAccessPositiveDecimal('01'), isEmpty);
    expect(compareGroupAccessUtf8('z', 'é'), lessThan(0));
    expect(
      () => GroupMemberAccessEntry.fromJson(
        _entry(
          conversationId: 'group-a',
          state: 'history_only',
          periods: [
            {'period_no': '1', 'from_seq': '1', 'to_seq': '10'},
            {'period_no': '2', 'from_seq': '10', 'to_seq': '20'},
          ],
        ),
      ),
      throwsFormatException,
    );

    final staging = GroupMemberAccessSnapshotStaging(
      organization: 1,
      minimumSnapshotId: '1',
    );
    staging.request('page-1');
    expect(
      () => staging.accept({
        'cmd': groupMemberAccessSnapshotAckCommand,
        'organization': 1,
        'client_msg_id': 'page-1',
        'data': {
          'access_snapshot_id': '1',
          'entries': [
            _entry(conversationId: 'group-b'),
            _entry(conversationId: 'group-a'),
          ],
          'next_cursor': null,
          'has_more': false,
        },
      }),
      throwsFormatException,
    );
  });

  test('连续撤权事件可立即缩减，恢复事件只触发权威重载', () async {
    final committedEntry = GroupMemberAccessEntry.fromJson(
      _entry(
        conversationId: 'group-a',
        accessVersion: '7',
        lastMessageSeq: '320',
        lastChangeSeq: '18',
      ),
    );
    final committed = GroupMemberAccessSnapshot(
      snapshotId: '42',
      entries: {'group-a': committedEntry},
    );
    final shrink = await GroupMemberAccessChanged.fromPacket(
      await _eventPacket(
        snapshotId: '43',
        accessVersion: '8',
        state: 'history_only',
        periods: [
          {'period_no': '1', 'from_seq': '1', 'to_seq': '320'},
        ],
        reason: 'leave',
      ),
      organization: 1,
      userId: 'user-01',
    );

    final shrinkProjection = projectGroupMemberAccessEvent(
      committed,
      shrink,
      const {},
    );
    expect(shrinkProjection.decision, GroupMemberAccessEventDecision.shrink);
    expect(
      shrinkProjection.snapshot!.entries['group-a']!.isHistoryOnly,
      isTrue,
    );

    final restore = await GroupMemberAccessChanged.fromPacket(
      await _eventPacket(
        snapshotId: '43',
        accessVersion: '8',
        state: 'active',
        periods: [
          {'period_no': '1', 'from_seq': '1', 'to_seq': null},
        ],
        reason: 'restore',
      ),
      organization: 1,
      userId: 'user-01',
    );
    expect(
      projectGroupMemberAccessEvent(committed, restore, const {}).decision,
      GroupMemberAccessEventDecision.reload,
    );
  });

  test('异步验签期间追加的撤权事件会被同一 drain epoch 消费', () async {
    final snapshot = GroupMemberAccessSnapshot(
      snapshotId: '42',
      entries: {
        'group-a': GroupMemberAccessEntry.fromJson(
          _entry(conversationId: 'group-a', accessVersion: '7'),
        ),
      },
    );
    final first = await _eventPacket(
      snapshotId: '42',
      accessVersion: '7',
      state: 'active',
      periods: [
        {'period_no': '1', 'from_seq': '1', 'to_seq': null},
      ],
      reason: 'join',
    );
    final revoke = await _eventPacket(
      snapshotId: '43',
      accessVersion: '8',
      state: 'revoked',
      periods: const [],
      reason: 'suspend',
    );
    final buffer = GroupMemberAccessEventBuffer()..add(first);
    final verificationStarted = Completer<void>();
    final releaseVerification = Completer<void>();
    var parseCount = 0;

    final draining = buffer.drain(
      snapshot: snapshot,
      parse: (packet) async {
        parseCount += 1;
        if (parseCount == 1) {
          verificationStarted.complete();
          await releaseVerification.future;
        }
        return GroupMemberAccessChanged.fromPacket(
          packet,
          organization: 1,
          userId: 'user-01',
        );
      },
    );
    await verificationStarted.future;
    buffer.add(revoke);
    releaseVerification.complete();

    final result = await draining;
    expect(parseCount, 2);
    expect(result.newerSnapshotId, '43');
    expect(result.eventIds, hasLength(2));
    expect(buffer.isCurrent(result.epoch), isTrue);
  });

  test('非法 surrogate、非 canonical SQL 时间与 reason/state 组合失败关闭', () async {
    expect(canonicalGroupAccessId('\uD800'), isEmpty);
    expect(() => compareGroupAccessUtf8('ok', '\uDC00'), throwsFormatException);

    final invalidTime = await _eventPacket(
      snapshotId: '43',
      accessVersion: '8',
      state: 'revoked',
      periods: const [],
      reason: 'suspend',
    );
    (invalidTime['data']! as Map<String, Object?>)['changed_at'] =
        '2026-02-30 16:00:00';
    await expectLater(
      GroupMemberAccessChanged.fromPacket(
        invalidTime,
        organization: 1,
        userId: 'user-01',
      ),
      throwsFormatException,
    );

    final rfc3339 = await _eventPacket(
      snapshotId: '43',
      accessVersion: '8',
      state: 'revoked',
      periods: const [],
      reason: 'suspend',
    );
    (rfc3339['data']! as Map<String, Object?>)['changed_at'] =
        '2026-07-20T16:00:00Z';
    await expectLater(
      GroupMemberAccessChanged.fromPacket(
        rfc3339,
        organization: 1,
        userId: 'user-01',
      ),
      throwsFormatException,
    );

    final mismatched = await _eventPacket(
      snapshotId: '43',
      accessVersion: '8',
      state: 'history_only',
      periods: [
        {'period_no': '1', 'from_seq': '1', 'to_seq': '320'},
      ],
      reason: 'suspend',
    );
    await expectLater(
      GroupMemberAccessChanged.fromPacket(
        mismatched,
        organization: 1,
        userId: 'user-01',
      ),
      throwsFormatException,
    );

    for (final invalid
        in <({String state, List<Map<String, Object?>> periods})>[
          (
            state: 'active',
            periods: [
              {'period_no': '1', 'from_seq': '1', 'to_seq': '10'},
            ],
          ),
          (
            state: 'history_only',
            periods: [
              {'period_no': '1', 'from_seq': '1', 'to_seq': null},
            ],
          ),
          (
            state: 'revoked',
            periods: [
              {'period_no': '1', 'from_seq': '1', 'to_seq': '10'},
            ],
          ),
        ]) {
      expect(
        () => GroupMemberAccessEntry.fromJson(
          _entry(
            conversationId: 'group-a',
            state: invalid.state,
            periods: invalid.periods,
          ),
          allowRevoked: true,
        ),
        throwsFormatException,
      );
    }

    for (final mismatch in <({String reason, String state})>[
      (reason: 'join', state: 'history_only'),
      (reason: 'leave', state: 'active'),
      (reason: 'history_revoke', state: 'active'),
    ]) {
      final packet = await _eventPacket(
        snapshotId: '43',
        accessVersion: '8',
        state: mismatch.state,
        periods: mismatch.state == 'active'
            ? [
                {'period_no': '1', 'from_seq': '1', 'to_seq': null},
              ]
            : [
                {'period_no': '1', 'from_seq': '1', 'to_seq': '320'},
              ],
        reason: mismatch.reason,
      );
      await expectLater(
        GroupMemberAccessChanged.fromPacket(
          packet,
          organization: 1,
          userId: 'user-01',
        ),
        throwsFormatException,
      );
    }
  });

  test('失效的事件缓冲拒绝提交并可清空后重新使用', () async {
    final buffer = GroupMemberAccessEventBuffer()..invalidate();
    final snapshot = GroupMemberAccessSnapshot(
      snapshotId: '42',
      entries: const {},
    );
    await expectLater(
      buffer.drain(
        snapshot: snapshot,
        parse: (packet) => GroupMemberAccessChanged.fromPacket(
          packet,
          organization: 1,
          userId: 'user-01',
        ),
      ),
      throwsFormatException,
    );
    buffer.clear();
    final result = await buffer.drain(
      snapshot: snapshot,
      parse: (packet) => GroupMemberAccessChanged.fromPacket(
        packet,
        organization: 1,
        userId: 'user-01',
      ),
    );
    expect(result.newerSnapshotId, isEmpty);
    expect(buffer.isCurrent(result.epoch), isTrue);
  });

  test('失效清理失败会传播并持续阻止新快照 ready', () async {
    final registry = GroupMemberAccessRegistry(
      organization: 1,
      userId: 'cleanup-failure-user',
    );
    await registry.replace(
      GroupMemberAccessSnapshot(snapshotId: '1', entries: const {}),
    );
    final cleanupStarted = Completer<void>();
    final releaseCleanup = Completer<void>();
    registry.captureEpoch().registerInvalidationCleanup(() async {
      cleanupStarted.complete();
      await releaseCleanup.future;
      throw const FormatException('injected cleanup failure');
    });

    registry.failClose();
    final replacement = registry.replace(
      GroupMemberAccessSnapshot(snapshotId: '2', entries: const {}),
    );
    await cleanupStarted.future;
    expect(registry.isReady, isFalse);
    releaseCleanup.complete();

    await expectLater(replacement, throwsFormatException);
    expect(registry.isReady, isFalse);
    expect(registry.captureEpoch, throwsStateError);
  });

  test('replacement snapshot 与 entry version 只允许单调前进', () async {
    final registry = GroupMemberAccessRegistry(
      organization: 1,
      userId: 'monotonic-replacement-user',
    );
    await registry.replace(_snapshot('5', accessVersion: '7'));

    expect(
      () => registry.replace(_snapshot('4', accessVersion: '8')),
      throwsStateError,
    );
    expect(registry.isReady, isFalse);

    await registry.replace(_snapshot('6', accessVersion: '8'));
    expect(registry.isReady, isTrue);
    expect(registry.snapshot!.snapshotId, '6');

    expect(
      () => registry.replace(_snapshot('7', accessVersion: '7')),
      throwsStateError,
    );
    expect(registry.isReady, isFalse);
    await registry.replace(_snapshot('7', accessVersion: '9'));
    expect(registry.isReady, isTrue);

    expect(
      () => registry.replace(
        _snapshot(
          '7',
          accessVersion: '9',
          periods: const [
            {'period_no': '1', 'from_seq': '2', 'to_seq': null},
          ],
        ),
      ),
      throwsStateError,
    );
    expect(registry.isReady, isFalse);
  });

  test('更旧 replacement 会使并发中的高版本 replacement 也失效', () async {
    final registry = GroupMemberAccessRegistry(
      organization: 1,
      userId: 'interleaved-replacement-user',
    );
    await registry.replace(_snapshot('5', accessVersion: '7'));
    final cleanupStarted = Completer<void>();
    final releaseCleanup = Completer<void>();
    registry.captureEpoch().registerInvalidationCleanup(() async {
      cleanupStarted.complete();
      await releaseCleanup.future;
    });

    final high = registry.beginReplacement(_snapshot('6', accessVersion: '8'));
    await cleanupStarted.future;
    expect(
      () => registry.beginReplacement(_snapshot('4', accessVersion: '9')),
      throwsStateError,
    );
    releaseCleanup.complete();
    await high.cleanup;
    expect(() => registry.commitReplacement(high), throwsStateError);
    expect(registry.isReady, isFalse);

    await registry.replace(_snapshot('6', accessVersion: '8'));
    expect(registry.isReady, isTrue);
    expect(registry.snapshot!.snapshotId, '6');
  });

  test('清理失败保留回调，后续同 snapshot replacement 可重试成功', () async {
    final registry = GroupMemberAccessRegistry(
      organization: 1,
      userId: 'retry-cleanup-user',
    );
    await registry.replace(_snapshot('1'));
    var attempts = 0;
    registry.captureEpoch().registerInvalidationCleanup(() {
      attempts += 1;
      if (attempts == 1) {
        throw const FormatException('first cleanup fails');
      }
    });

    await expectLater(registry.replace(_snapshot('2')), throwsFormatException);
    expect(registry.isReady, isFalse);
    expect(attempts, 1);

    await registry.replace(_snapshot('2'));
    expect(attempts, 2);
    expect(registry.isReady, isTrue);
    expect(registry.snapshot!.snapshotId, '2');
  });

  test('实时 shrink 必须精确匹配 reason、前态、period_no 与关闭边界', () async {
    final active = GroupMemberAccessSnapshot(
      snapshotId: '42',
      entries: {
        'group-a': GroupMemberAccessEntry.fromJson(
          _entry(
            conversationId: 'group-a',
            accessVersion: '7',
            lastMessageSeq: '25',
            periods: const [
              {'period_no': '1', 'from_seq': '1', 'to_seq': '10'},
              {'period_no': '2', 'from_seq': '20', 'to_seq': null},
            ],
          ),
        ),
      },
    );
    Future<GroupMemberAccessEventDecision> decision({
      required String reason,
      required String state,
      required List<Map<String, Object?>> periods,
      GroupMemberAccessSnapshot? snapshot,
    }) async {
      final event = await GroupMemberAccessChanged.fromPacket(
        await _eventPacket(
          snapshotId: '43',
          accessVersion: '8',
          state: state,
          periods: periods,
          reason: reason,
        ),
        organization: 1,
        userId: 'user-01',
      );
      return projectGroupMemberAccessEvent(
        snapshot ?? active,
        event,
        const {},
      ).decision;
    }

    expect(
      await decision(
        reason: 'leave',
        state: 'history_only',
        periods: const [
          {'period_no': '1', 'from_seq': '1', 'to_seq': '10'},
          {'period_no': '2', 'from_seq': '20', 'to_seq': '320'},
        ],
      ),
      GroupMemberAccessEventDecision.shrink,
    );
    for (final malformed in <List<Map<String, Object?>>>[
      const [
        {'period_no': '1', 'from_seq': '1', 'to_seq': '10'},
        {'period_no': '3', 'from_seq': '20', 'to_seq': '320'},
      ],
      const [
        {'period_no': '1', 'from_seq': '1', 'to_seq': '10'},
        {'period_no': '2', 'from_seq': '20', 'to_seq': '319'},
      ],
      const [
        {'period_no': '2', 'from_seq': '20', 'to_seq': '320'},
      ],
    ]) {
      expect(
        await decision(
          reason: 'leave',
          state: 'history_only',
          periods: malformed,
        ),
        GroupMemberAccessEventDecision.reload,
      );
    }

    final history = GroupMemberAccessSnapshot(
      snapshotId: '42',
      entries: {
        'group-a': GroupMemberAccessEntry.fromJson(
          _entry(
            conversationId: 'group-a',
            accessVersion: '7',
            state: 'history_only',
            periods: const [
              {'period_no': '1', 'from_seq': '1', 'to_seq': '10'},
              {'period_no': '2', 'from_seq': '20', 'to_seq': '30'},
            ],
          ),
        ),
      },
    );
    expect(
      await decision(
        snapshot: history,
        reason: 'history_revoke',
        state: 'history_only',
        periods: const [
          {'period_no': '2', 'from_seq': '20', 'to_seq': '30'},
        ],
      ),
      GroupMemberAccessEventDecision.shrink,
    );
    expect(
      await decision(
        snapshot: history,
        reason: 'history_revoke',
        state: 'history_only',
        periods: const [
          {'period_no': '2', 'from_seq': '21', 'to_seq': '30'},
        ],
      ),
      GroupMemberAccessEventDecision.reload,
    );
    expect(
      await decision(
        snapshot: history,
        reason: 'leave',
        state: 'history_only',
        periods: const [
          {'period_no': '1', 'from_seq': '1', 'to_seq': '10'},
          {'period_no': '2', 'from_seq': '20', 'to_seq': '30'},
        ],
      ),
      GroupMemberAccessEventDecision.reload,
    );
  });
}

GroupMemberAccessSnapshot _snapshot(
  String snapshotId, {
  String accessVersion = '1',
  List<Map<String, Object?>>? periods,
}) => GroupMemberAccessSnapshot(
  snapshotId: snapshotId,
  entries: {
    'group-a': GroupMemberAccessEntry.fromJson(
      _entry(
        conversationId: 'group-a',
        accessVersion: accessVersion,
        periods: periods,
      ),
    ),
  },
);

Map<String, Object?> _entry({
  required String conversationId,
  String accessVersion = '1',
  String state = 'active',
  String lastMessageSeq = '100',
  String lastChangeSeq = '10',
  List<Map<String, Object?>>? periods,
}) => {
  'conversation_id': conversationId,
  'conversation_type': 2,
  'access_version': accessVersion,
  'access_state': state,
  'last_message_seq': lastMessageSeq,
  'last_change_seq': lastChangeSeq,
  'periods':
      periods ??
      [
        {'period_no': '1', 'from_seq': '1', 'to_seq': null},
      ],
};

Future<Map<String, Object?>> _eventPacket({
  required String snapshotId,
  required String accessVersion,
  required String state,
  required List<Map<String, Object?>> periods,
  required String reason,
}) async {
  final canonical = [
    '1',
    groupMemberAccessChangedEventType,
    'group-a',
    '1',
    'user-01',
    snapshotId,
    accessVersion,
  ].join('|');
  final digest = await Sha256().hash(utf8.encode(canonical));
  final eventId = digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return {
    'cmd': groupMemberAccessChangedCommand,
    'organization': 1,
    'data': {
      'event_id': eventId,
      'event_type': groupMemberAccessChangedEventType,
      'target_organization': 1,
      'target_user_id': 'user-01',
      'conversation_id': 'group-a',
      'conversation_type': 2,
      'access_snapshot_id': snapshotId,
      'access_version': accessVersion,
      'access_state': state,
      'last_message_seq': '320',
      'last_change_seq': '18',
      'periods': periods,
      'reason': reason,
      'changed_at': '2026-07-20 16:00:00',
    },
  };
}
