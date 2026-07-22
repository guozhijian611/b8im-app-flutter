import 'dart:collection';
import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

const groupMemberAccessSnapshotCommand = 'group_member_access_snapshot';
const groupMemberAccessSnapshotAckCommand = 'group_member_access_snapshot_ack';
const groupMemberAccessChangedCommand = 'group_member_access_changed';
const groupMemberAccessChangedEventType = 'group.member_access_changed';

final _uint64Maximum = BigInt.parse('18446744073709551615');
final _positivePattern = RegExp(r'^[1-9][0-9]{0,19}$');
final _nonNegativePattern = RegExp(r'^(0|[1-9][0-9]{0,19})$');

String normalizeGroupAccessPositiveDecimal(Object? value) =>
    value is String &&
        _positivePattern.hasMatch(value) &&
        BigInt.parse(value) <= _uint64Maximum
    ? value
    : '';

String normalizeGroupAccessNonNegativeDecimal(Object? value) =>
    value is String &&
        _nonNegativePattern.hasMatch(value) &&
        BigInt.parse(value) <= _uint64Maximum
    ? value
    : '';

String canonicalGroupAccessId(Object? value) =>
    value is String &&
        value.isNotEmpty &&
        value.trim() == value &&
        !_hasUnpairedSurrogate(value) &&
        utf8.encode(value).length <= 64 &&
        !value.codeUnits.contains(0) &&
        !value.contains('|')
    ? value
    : '';

int compareGroupAccessDecimals(String left, String right) {
  if (normalizeGroupAccessNonNegativeDecimal(left).isEmpty ||
      normalizeGroupAccessNonNegativeDecimal(right).isEmpty) {
    throw const FormatException('群访问版本不是规范 uint64 十进制');
  }
  return BigInt.parse(left).compareTo(BigInt.parse(right));
}

String nextGroupAccessDecimal(String value) {
  if (normalizeGroupAccessNonNegativeDecimal(value).isEmpty) return '';
  final next = BigInt.parse(value) + BigInt.one;
  return next <= _uint64Maximum ? next.toString() : '';
}

int compareGroupAccessUtf8(String left, String right) {
  if (_hasUnpairedSurrogate(left) || _hasUnpairedSurrogate(right)) {
    throw const FormatException('群访问字符串包含非法 surrogate');
  }
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  final length = a.length < b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    if (a[index] != b[index]) return a[index].compareTo(b[index]);
  }
  return a.length.compareTo(b.length);
}

bool _hasUnpairedSurrogate(String value) {
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (index + 1 >= value.length) return true;
      final next = value.codeUnitAt(index + 1);
      if (next < 0xDC00 || next > 0xDFFF) return true;
      index += 1;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

enum GroupMemberAccessState { active, historyOnly, revoked }

extension GroupMemberAccessStateWire on GroupMemberAccessState {
  String get wireName => switch (this) {
    GroupMemberAccessState.active => 'active',
    GroupMemberAccessState.historyOnly => 'history_only',
    GroupMemberAccessState.revoked => 'revoked',
  };
}

GroupMemberAccessState? _state(Object? value) => switch (value) {
  'active' => GroupMemberAccessState.active,
  'history_only' => GroupMemberAccessState.historyOnly,
  'revoked' => GroupMemberAccessState.revoked,
  _ => null,
};

final class GroupMemberAccessPeriod {
  const GroupMemberAccessPeriod({
    required this.periodNo,
    required this.fromSeq,
    required this.toSeq,
  });

  factory GroupMemberAccessPeriod.fromJson(
    Object? value,
    GroupMemberAccessState state,
  ) {
    final map = _strictMap(value, 'period');
    if (map.length != 3 ||
        !map.keys.toSet().containsAll({'period_no', 'from_seq', 'to_seq'})) {
      throw const FormatException('群访问 period schema 无效');
    }
    final periodNo = normalizeGroupAccessPositiveDecimal(map['period_no']);
    final fromSeq = normalizeGroupAccessPositiveDecimal(map['from_seq']);
    final rawToSeq = map['to_seq'];
    final toSeq = rawToSeq == null
        ? null
        : normalizeGroupAccessPositiveDecimal(rawToSeq);
    if (periodNo.isEmpty ||
        fromSeq.isEmpty ||
        (rawToSeq != null && toSeq!.isEmpty) ||
        (toSeq != null && compareGroupAccessDecimals(toSeq, fromSeq) < 0) ||
        (toSeq == null && state != GroupMemberAccessState.active)) {
      throw const FormatException('群访问 period 标量无效');
    }
    return GroupMemberAccessPeriod(
      periodNo: periodNo,
      fromSeq: fromSeq,
      toSeq: toSeq,
    );
  }

  final String periodNo;
  final String fromSeq;
  final String? toSeq;

  bool contains(int sequence) =>
      sequence > 0 &&
      compareGroupAccessDecimals('$sequence', fromSeq) >= 0 &&
      (toSeq == null || compareGroupAccessDecimals('$sequence', toSeq!) <= 0);

  bool containsPeriod(GroupMemberAccessPeriod candidate) =>
      compareGroupAccessDecimals(candidate.fromSeq, fromSeq) >= 0 &&
      (toSeq == null ||
          (candidate.toSeq != null &&
              compareGroupAccessDecimals(candidate.toSeq!, toSeq!) <= 0));
}

final class GroupMemberAccessEntry {
  const GroupMemberAccessEntry({
    required this.conversationId,
    required this.accessVersion,
    required this.accessState,
    required this.lastMessageSeq,
    required this.lastChangeSeq,
    required this.periods,
  });

  factory GroupMemberAccessEntry.fromJson(
    Object? value, {
    bool allowRevoked = false,
  }) {
    final map = _strictMap(value, 'group access entry');
    const keys = {
      'conversation_id',
      'conversation_type',
      'access_version',
      'access_state',
      'last_message_seq',
      'last_change_seq',
      'periods',
    };
    final conversationId = canonicalGroupAccessId(map['conversation_id']);
    final accessVersion = normalizeGroupAccessPositiveDecimal(
      map['access_version'],
    );
    final accessState = _state(map['access_state']);
    final lastMessageSeq = normalizeGroupAccessNonNegativeDecimal(
      map['last_message_seq'],
    );
    final lastChangeSeq = normalizeGroupAccessNonNegativeDecimal(
      map['last_change_seq'],
    );
    final rawPeriods = map['periods'];
    if (map.length != keys.length ||
        !map.keys.toSet().containsAll(keys) ||
        conversationId.isEmpty ||
        map['conversation_type'] != 2 ||
        accessVersion.isEmpty ||
        accessState == null ||
        (!allowRevoked && accessState == GroupMemberAccessState.revoked) ||
        lastMessageSeq.isEmpty ||
        lastChangeSeq.isEmpty ||
        rawPeriods is! List) {
      throw const FormatException('群访问 entry schema 或标量无效');
    }
    final periods = rawPeriods
        .map((item) => GroupMemberAccessPeriod.fromJson(item, accessState))
        .toList(growable: false);
    _validatePeriods(periods, accessState);
    return GroupMemberAccessEntry(
      conversationId: conversationId,
      accessVersion: accessVersion,
      accessState: accessState,
      lastMessageSeq: lastMessageSeq,
      lastChangeSeq: lastChangeSeq,
      periods: List.unmodifiable(periods),
    );
  }

  final String conversationId;
  final String accessVersion;
  final GroupMemberAccessState accessState;
  final String lastMessageSeq;
  final String lastChangeSeq;
  final List<GroupMemberAccessPeriod> periods;

  bool get isActive => accessState == GroupMemberAccessState.active;
  bool get isHistoryOnly => accessState == GroupMemberAccessState.historyOnly;
  bool containsMessageSequence(int sequence) =>
      containsMessageSequenceDecimal('$sequence');
  bool containsMessageSequenceDecimal(String sequence) =>
      normalizeGroupAccessPositiveDecimal(sequence).isNotEmpty &&
      periods.any(
        (period) =>
            compareGroupAccessDecimals(sequence, period.fromSeq) >= 0 &&
            (period.toSeq == null ||
                compareGroupAccessDecimals(sequence, period.toSeq!) <= 0),
      );
}

void _validatePeriods(
  List<GroupMemberAccessPeriod> periods,
  GroupMemberAccessState state,
) {
  if ((state == GroupMemberAccessState.revoked && periods.isNotEmpty) ||
      (state != GroupMemberAccessState.revoked && periods.isEmpty)) {
    throw const FormatException('群访问状态与 periods 不一致');
  }
  var openPeriods = 0;
  GroupMemberAccessPeriod? previous;
  for (final period in periods) {
    if (period.toSeq == null) openPeriods += 1;
    if (previous != null &&
        (compareGroupAccessDecimals(period.periodNo, previous.periodNo) <= 0 ||
            previous.toSeq == null ||
            compareGroupAccessDecimals(period.fromSeq, previous.toSeq!) <= 0)) {
      throw const FormatException('群访问 periods 未严格递增或存在重叠');
    }
    previous = period;
  }
  if ((state == GroupMemberAccessState.active &&
          (openPeriods != 1 || periods.last.toSeq != null)) ||
      (state != GroupMemberAccessState.active && openPeriods != 0)) {
    throw const FormatException('群访问开放 period 与状态不一致');
  }
}

final class GroupMemberAccessSnapshot {
  GroupMemberAccessSnapshot({
    required this.snapshotId,
    required Map<String, GroupMemberAccessEntry> entries,
  }) : entries = UnmodifiableMapView(Map.of(entries));

  final String snapshotId;
  final Map<String, GroupMemberAccessEntry> entries;
}

final class GroupMemberAccessSnapshotPage {
  const GroupMemberAccessSnapshotPage({
    required this.snapshotId,
    required this.entries,
    required this.nextCursor,
    required this.hasMore,
  });

  factory GroupMemberAccessSnapshotPage.fromPacket(
    Map<String, Object?> packet, {
    required int organization,
    required String clientMessageId,
    required String? expectedSnapshotId,
    required String previousConversationId,
  }) {
    if (packet['cmd'] != groupMemberAccessSnapshotAckCommand ||
        packet['organization'] != organization ||
        packet['client_msg_id'] != clientMessageId) {
      throw const FormatException('群访问快照页未绑定当前请求');
    }
    final data = _strictMap(packet['data'], 'group access snapshot ACK');
    const keys = {'access_snapshot_id', 'entries', 'next_cursor', 'has_more'};
    final snapshotId = normalizeGroupAccessPositiveDecimal(
      data['access_snapshot_id'],
    );
    final rawEntries = data['entries'];
    final hasMore = data['has_more'];
    final rawCursor = data['next_cursor'];
    final cursor =
        rawCursor is String &&
            rawCursor.isNotEmpty &&
            rawCursor.trim() == rawCursor &&
            !_hasUnpairedSurrogate(rawCursor) &&
            utf8.encode(rawCursor).length <= 512 &&
            !rawCursor.codeUnits.contains(0)
        ? rawCursor
        : null;
    if (data.length != keys.length ||
        !data.keys.toSet().containsAll(keys) ||
        snapshotId.isEmpty ||
        (expectedSnapshotId != null && snapshotId != expectedSnapshotId) ||
        rawEntries is! List ||
        hasMore is! bool ||
        (hasMore && (cursor == null || rawEntries.isEmpty)) ||
        (!hasMore && rawCursor != null) ||
        (rawCursor != null && cursor == null)) {
      throw const FormatException('群访问快照页 schema 或标量无效');
    }
    final entries = <GroupMemberAccessEntry>[];
    var previous = previousConversationId;
    for (final item in rawEntries) {
      final entry = GroupMemberAccessEntry.fromJson(item);
      if (previous.isNotEmpty &&
          compareGroupAccessUtf8(entry.conversationId, previous) <= 0) {
        throw const FormatException('群访问快照页顺序或唯一性无效');
      }
      entries.add(entry);
      previous = entry.conversationId;
    }
    return GroupMemberAccessSnapshotPage(
      snapshotId: snapshotId,
      entries: List.unmodifiable(entries),
      nextCursor: cursor,
      hasMore: hasMore,
    );
  }

  final String snapshotId;
  final List<GroupMemberAccessEntry> entries;
  final String? nextCursor;
  final bool hasMore;
}

final class GroupMemberAccessSnapshotStaging {
  GroupMemberAccessSnapshotStaging({
    required this.organization,
    required this.minimumSnapshotId,
    this.limit = 100,
  }) {
    if (organization <= 0 ||
        normalizeGroupAccessPositiveDecimal(minimumSnapshotId).isEmpty ||
        limit < 1 ||
        limit > 200) {
      throw const FormatException('群访问 snapshot staging 初始化无效');
    }
  }

  final int organization;
  final String minimumSnapshotId;
  final int limit;
  final List<GroupMemberAccessEntry> _entries = [];
  String _snapshotId = '';
  String? _nextCursor;
  String _previousConversationId = '';
  String _pendingClientMessageId = '';
  bool _complete = false;

  bool get hasMore => !_complete;

  Map<String, Object?> request(String clientMessageId) {
    if (_complete ||
        _pendingClientMessageId.isNotEmpty ||
        canonicalGroupAccessId(clientMessageId).isEmpty) {
      throw StateError('群访问快照页请求状态无效');
    }
    _pendingClientMessageId = clientMessageId;
    return {
      'cmd': groupMemberAccessSnapshotCommand,
      'client_msg_id': clientMessageId,
      'data': {
        'access_snapshot_id': _snapshotId.isEmpty ? null : _snapshotId,
        'cursor': _nextCursor,
        'limit': limit,
      },
    };
  }

  GroupMemberAccessSnapshotPage accept(Map<String, Object?> packet) {
    if (_pendingClientMessageId.isEmpty) {
      throw StateError('收到未请求的群访问快照页');
    }
    try {
      final page = GroupMemberAccessSnapshotPage.fromPacket(
        packet,
        organization: organization,
        clientMessageId: _pendingClientMessageId,
        expectedSnapshotId: _snapshotId.isEmpty ? null : _snapshotId,
        previousConversationId: _previousConversationId,
      );
      if (page.entries.length > limit) {
        throw const FormatException('群访问快照页超过请求 limit');
      }
      if (_snapshotId.isEmpty &&
          compareGroupAccessDecimals(page.snapshotId, minimumSnapshotId) < 0) {
        throw const FormatException('群访问快照早于 AUTH 水位');
      }
      _snapshotId = _snapshotId.isEmpty ? page.snapshotId : _snapshotId;
      _entries.addAll(page.entries);
      if (page.entries.isNotEmpty) {
        _previousConversationId = page.entries.last.conversationId;
      }
      _nextCursor = page.nextCursor;
      _complete = !page.hasMore;
      return page;
    } finally {
      _pendingClientMessageId = '';
    }
  }

  GroupMemberAccessSnapshot committed() {
    if (!_complete || _snapshotId.isEmpty) {
      throw StateError('群访问快照页链尚未完成');
    }
    return GroupMemberAccessSnapshot(
      snapshotId: _snapshotId,
      entries: {for (final entry in _entries) entry.conversationId: entry},
    );
  }

  void discard() {
    _entries.clear();
    _snapshotId = '';
    _nextCursor = null;
    _previousConversationId = '';
    _pendingClientMessageId = '';
    _complete = false;
  }
}

final class GroupMemberAccessChanged {
  const GroupMemberAccessChanged({
    required this.eventId,
    required this.snapshotId,
    required this.entry,
    required this.reason,
    required this.changedAt,
  });

  static Future<GroupMemberAccessChanged> fromPacket(
    Map<String, Object?> packet, {
    required int organization,
    required String userId,
  }) async {
    final canonicalUserId = canonicalGroupAccessId(userId);
    if (organization <= 0 ||
        canonicalUserId.isEmpty ||
        packet['cmd'] != groupMemberAccessChangedCommand ||
        packet['organization'] != organization) {
      throw const FormatException('群访问事件 envelope 或目标身份无效');
    }
    final data = _strictMap(packet['data'], 'group access changed');
    const keys = {
      'event_id',
      'event_type',
      'target_organization',
      'target_user_id',
      'conversation_id',
      'conversation_type',
      'access_snapshot_id',
      'access_version',
      'access_state',
      'last_message_seq',
      'last_change_seq',
      'periods',
      'reason',
      'changed_at',
    };
    final eventId = data['event_id'];
    final snapshotId = normalizeGroupAccessPositiveDecimal(
      data['access_snapshot_id'],
    );
    final reason = data['reason'];
    final changedAt = data['changed_at'];
    if (data.length != keys.length ||
        !data.keys.toSet().containsAll(keys) ||
        eventId is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(eventId) ||
        data['event_type'] != groupMemberAccessChangedEventType ||
        data['target_organization'] != organization ||
        data['target_user_id'] != canonicalUserId ||
        snapshotId.isEmpty ||
        reason is! String ||
        !const {
          'join',
          'leave',
          'remove',
          'suspend',
          'restore',
          'history_revoke',
        }.contains(reason) ||
        changedAt is! String ||
        !_isCanonicalSqlDateTime(changedAt)) {
      throw const FormatException('群访问事件 schema 或标量无效');
    }
    final entry = GroupMemberAccessEntry.fromJson({
      'conversation_id': data['conversation_id'],
      'conversation_type': data['conversation_type'],
      'access_version': data['access_version'],
      'access_state': data['access_state'],
      'last_message_seq': data['last_message_seq'],
      'last_change_seq': data['last_change_seq'],
      'periods': data['periods'],
    }, allowRevoked: true);
    if (!_reasonMatchesState(reason, entry.accessState)) {
      throw const FormatException('群访问事件 reason 与状态语义不一致');
    }
    final canonical = [
      '$organization',
      groupMemberAccessChangedEventType,
      entry.conversationId,
      '$organization',
      canonicalUserId,
      snapshotId,
      entry.accessVersion,
    ].join('|');
    final digest = await Sha256().hash(utf8.encode(canonical));
    final expected = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    if (eventId != expected) {
      throw const FormatException('群访问事件 event_id 与规范身份不一致');
    }
    return GroupMemberAccessChanged(
      eventId: eventId,
      snapshotId: snapshotId,
      entry: entry,
      reason: reason,
      changedAt: changedAt,
    );
  }

  final String eventId;
  final String snapshotId;
  final GroupMemberAccessEntry entry;
  final String reason;
  final String changedAt;
}

bool _reasonMatchesState(String reason, GroupMemberAccessState state) =>
    switch (reason) {
      'join' || 'restore' => state == GroupMemberAccessState.active,
      'leave' || 'remove' || 'history_revoke' =>
        state == GroupMemberAccessState.historyOnly ||
            state == GroupMemberAccessState.revoked,
      'suspend' => state == GroupMemberAccessState.revoked,
      _ => false,
    };

bool _isCanonicalSqlDateTime(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$',
  ).firstMatch(value);
  if (match == null || _hasUnpairedSurrogate(value)) return false;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  if (year == 0 || hour > 23 || minute > 59 || second > 59) {
    return false;
  }
  final calendar = DateTime.utc(year, month, day);
  return calendar.year == year &&
      calendar.month == month &&
      calendar.day == day;
}

final class GroupMemberAccessEventDrainResult {
  const GroupMemberAccessEventDrainResult({
    required this.epoch,
    required this.newerSnapshotId,
    required this.eventIds,
  });

  final int epoch;
  final String newerSnapshotId;
  final List<String> eventIds;
}

final class GroupMemberAccessEventBuffer {
  final List<Map<String, Object?>> _packets = [];
  int _epoch = 0;
  bool _invalid = false;

  int get length => _packets.length;
  int get epoch => _epoch;

  void add(Map<String, Object?> packet) {
    if (_invalid) return;
    _packets.add(Map.unmodifiable(packet));
    _epoch += 1;
  }

  void invalidate() {
    _invalid = true;
    _epoch += 1;
  }

  bool isCurrent(int expectedEpoch) => expectedEpoch == _epoch;

  Future<GroupMemberAccessEventDrainResult> drain({
    required GroupMemberAccessSnapshot snapshot,
    required Future<GroupMemberAccessChanged> Function(
      Map<String, Object?> packet,
    )
    parse,
  }) async {
    if (_invalid) throw const FormatException('群访问实时事件缓冲已失效');
    var index = 0;
    var newerSnapshotId = '';
    final eventIds = <String>[];
    while (true) {
      final observedEpoch = _epoch;
      while (index < _packets.length) {
        final event = await parse(_packets[index]);
        if (_invalid) throw const FormatException('群访问实时事件缓冲已失效');
        index += 1;
        eventIds.add(event.eventId);
        if (compareGroupAccessDecimals(event.snapshotId, snapshot.snapshotId) >
                0 &&
            (newerSnapshotId.isEmpty ||
                compareGroupAccessDecimals(event.snapshotId, newerSnapshotId) >
                    0)) {
          newerSnapshotId = event.snapshotId;
        }
      }
      if (observedEpoch == _epoch && index == _packets.length) {
        return GroupMemberAccessEventDrainResult(
          epoch: observedEpoch,
          newerSnapshotId: newerSnapshotId,
          eventIds: List.unmodifiable(eventIds),
        );
      }
    }
  }

  void clear() {
    _packets.clear();
    _invalid = false;
    _epoch += 1;
  }
}

enum GroupMemberAccessEventDecision { stale, duplicate, shrink, reload }

final class GroupMemberAccessEventProjection {
  const GroupMemberAccessEventProjection(this.decision, this.snapshot);

  final GroupMemberAccessEventDecision decision;
  final GroupMemberAccessSnapshot? snapshot;
}

GroupMemberAccessEventProjection projectGroupMemberAccessEvent(
  GroupMemberAccessSnapshot committed,
  GroupMemberAccessChanged event,
  Set<String> seenEventIds,
) {
  final snapshotComparison = compareGroupAccessDecimals(
    event.snapshotId,
    committed.snapshotId,
  );
  if (snapshotComparison < 0) {
    return const GroupMemberAccessEventProjection(
      GroupMemberAccessEventDecision.stale,
      null,
    );
  }
  if (snapshotComparison == 0) {
    return GroupMemberAccessEventProjection(
      seenEventIds.contains(event.eventId)
          ? GroupMemberAccessEventDecision.duplicate
          : GroupMemberAccessEventDecision.reload,
      null,
    );
  }
  final current = committed.entries[event.entry.conversationId];
  final shrinking =
      current != null &&
      event.snapshotId == nextGroupAccessDecimal(committed.snapshotId) &&
      event.entry.accessVersion ==
          nextGroupAccessDecimal(current.accessVersion) &&
      compareGroupAccessDecimals(
            event.entry.lastMessageSeq,
            current.lastMessageSeq,
          ) >=
          0 &&
      compareGroupAccessDecimals(
            event.entry.lastChangeSeq,
            current.lastChangeSeq,
          ) >=
          0 &&
      _isExactGroupAccessShrink(current, event);
  if (!shrinking) {
    return const GroupMemberAccessEventProjection(
      GroupMemberAccessEventDecision.reload,
      null,
    );
  }
  final entries = Map<String, GroupMemberAccessEntry>.of(committed.entries);
  if (event.entry.accessState == GroupMemberAccessState.revoked) {
    entries.remove(event.entry.conversationId);
  } else {
    entries[event.entry.conversationId] = event.entry;
  }
  return GroupMemberAccessEventProjection(
    GroupMemberAccessEventDecision.shrink,
    GroupMemberAccessSnapshot(snapshotId: event.snapshotId, entries: entries),
  );
}

bool _isExactGroupAccessShrink(
  GroupMemberAccessEntry current,
  GroupMemberAccessChanged event,
) {
  final next = event.entry;
  switch (event.reason) {
    case 'leave':
    case 'remove':
      if (!current.isActive) return false;
      final expected = <GroupMemberAccessPeriod>[
        ...current.periods.take(current.periods.length - 1),
      ];
      final open = current.periods.last;
      if (open.toSeq != null) return false;
      if (compareGroupAccessDecimals(next.lastMessageSeq, open.fromSeq) >= 0) {
        expected.add(
          GroupMemberAccessPeriod(
            periodNo: open.periodNo,
            fromSeq: open.fromSeq,
            toSeq: next.lastMessageSeq,
          ),
        );
      }
      final expectedState = expected.isEmpty
          ? GroupMemberAccessState.revoked
          : GroupMemberAccessState.historyOnly;
      return next.accessState == expectedState &&
          _sameGroupAccessPeriods(next.periods, expected);
    case 'suspend':
      return current.isActive &&
          next.accessState == GroupMemberAccessState.revoked &&
          next.periods.isEmpty;
    case 'history_revoke':
      if (!current.isHistoryOnly ||
          next.accessState == GroupMemberAccessState.active ||
          next.periods.length >= current.periods.length ||
          !next.periods.every(
            (period) => current.periods.any(
              (candidate) => _sameGroupAccessPeriod(period, candidate),
            ),
          )) {
        return false;
      }
      return (next.periods.isEmpty &&
              next.accessState == GroupMemberAccessState.revoked) ||
          (next.periods.isNotEmpty &&
              next.accessState == GroupMemberAccessState.historyOnly);
    case 'join':
    case 'restore':
      return false;
  }
  return false;
}

bool _sameGroupAccessPeriods(
  List<GroupMemberAccessPeriod> left,
  List<GroupMemberAccessPeriod> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (!_sameGroupAccessPeriod(left[index], right[index])) return false;
  }
  return true;
}

bool _sameGroupAccessPeriod(
  GroupMemberAccessPeriod left,
  GroupMemberAccessPeriod right,
) =>
    left.periodNo == right.periodNo &&
    left.fromSeq == right.fromSeq &&
    left.toSeq == right.toSeq;

bool _sameGroupAccessEntry(
  GroupMemberAccessEntry left,
  GroupMemberAccessEntry right,
) =>
    left.conversationId == right.conversationId &&
    left.accessVersion == right.accessVersion &&
    left.accessState == right.accessState &&
    left.lastMessageSeq == right.lastMessageSeq &&
    left.lastChangeSeq == right.lastChangeSeq &&
    _sameGroupAccessPeriods(left.periods, right.periods);

bool _sameGroupAccessSnapshot(
  GroupMemberAccessSnapshot left,
  GroupMemberAccessSnapshot right,
) {
  if (left.snapshotId != right.snapshotId ||
      left.entries.length != right.entries.length) {
    return false;
  }
  for (final item in left.entries.entries) {
    final candidate = right.entries[item.key];
    if (candidate == null || !_sameGroupAccessEntry(item.value, candidate)) {
      return false;
    }
  }
  return true;
}

typedef GroupMemberAccessInvalidationCallback = FutureOr<void> Function();

final class GroupMemberAccessInvalidationRegistration {
  GroupMemberAccessInvalidationRegistration._(
    this._registry,
    this._generation,
    this._id,
  );

  final GroupMemberAccessRegistry _registry;
  final int _generation;
  final int _id;
  bool _active = true;

  void cancel() {
    if (!_active) return;
    _active = false;
    _registry._removeInvalidationCallback(_generation, _id);
  }
}

final class GroupMemberAccessReplacement {
  const GroupMemberAccessReplacement._({
    required this.registry,
    required this.generation,
    required this.snapshot,
    required this.cleanup,
    required this.immediatelyClean,
  });

  final GroupMemberAccessRegistry registry;
  final int generation;
  final GroupMemberAccessSnapshot snapshot;
  final Future<void> cleanup;
  final bool immediatelyClean;
}

final class GroupMemberAccessEpoch {
  const GroupMemberAccessEpoch._(
    this._registry,
    this.generation,
    this.invalidated,
  );

  final GroupMemberAccessRegistry _registry;
  final int generation;
  final Future<void> invalidated;

  void assertCurrent() {
    if (!_registry.isReady || _registry.generation != generation) {
      throw StateError('群访问快照已变化，旧请求结果已丢弃');
    }
  }

  GroupMemberAccessInvalidationRegistration registerInvalidationCleanup(
    GroupMemberAccessInvalidationCallback callback,
  ) {
    assertCurrent();
    return _registry._registerInvalidationCallback(generation, callback);
  }
}

final class GroupMemberAccessRegistry {
  GroupMemberAccessRegistry({
    required this.organization,
    required String userId,
  }) : userId = canonicalGroupAccessId(userId) {
    if (organization <= 0 || this.userId.isEmpty) {
      throw const FormatException('群访问 registry 复合身份无效');
    }
    _scopes[_scope(organization, this.userId)] = this;
  }

  static final Map<String, GroupMemberAccessRegistry> _scopes = {};
  static String _scope(int organization, String userId) =>
      '$organization:$userId';

  static GroupMemberAccessRegistry? lookup(int organization, String userId) =>
      _scopes[_scope(organization, canonicalGroupAccessId(userId))];

  final int organization;
  final String userId;
  final LinkedHashSet<String> _seenEventIds = LinkedHashSet();
  GroupMemberAccessSnapshot? _snapshot;
  bool _ready = false;
  int _generation = 0;
  Completer<void> _generationInvalidation = Completer<void>();
  final Map<int, Map<int, GroupMemberAccessInvalidationCallback>>
  _invalidationCallbacks = {};
  final Map<int, GroupMemberAccessInvalidationCallback>
  _pendingInvalidationCallbacks = {};
  int _nextInvalidationCallbackId = 0;
  Future<void>? _activeCleanup;
  int _cleanupPending = 0;
  Object? _cleanupFailure;
  String _replacementSnapshotHighWater = '0';
  GroupMemberAccessSnapshot? _replacementSnapshotAtHighWater;
  final Map<String, String> _entryVersionHighWater = {};
  final Map<String, GroupMemberAccessEntry> _entryAtVersionHighWater = {};

  GroupMemberAccessSnapshot? get snapshot => _snapshot;
  bool get isReady => _ready && _snapshot != null;
  int get generation => _generation;
  GroupMemberAccessEntry? entry(String conversationId) => isReady
      ? _snapshot!.entries[canonicalGroupAccessId(conversationId)]
      : null;

  GroupMemberAccessEpoch captureEpoch() {
    assertReady();
    return GroupMemberAccessEpoch._(
      this,
      _generation,
      _generationInvalidation.future,
    );
  }

  void assertReady() {
    if (!isReady) throw StateError('群成员访问快照尚未就绪');
  }

  GroupMemberAccessEntry assertVisible(String conversationId) {
    assertReady();
    final value = entry(conversationId);
    if (value == null) throw StateError('当前群会话不可访问');
    return value;
  }

  GroupMemberAccessEntry assertActive(String conversationId) {
    final value = assertVisible(conversationId);
    if (!value.isActive) throw StateError('当前群成员访问不允许此操作');
    return value;
  }

  void failClose() {
    _ready = false;
    unawaited(_advanceGeneration().then<void>((_) {}, onError: (_, _) {}));
  }

  GroupMemberAccessReplacement beginReplacement(
    GroupMemberAccessSnapshot snapshot,
  ) {
    final immutable = GroupMemberAccessSnapshot(
      snapshotId: snapshot.snapshotId,
      entries: snapshot.entries,
    );
    try {
      _validateReplacement(immutable);
    } on Object {
      _ready = false;
      unawaited(_advanceGeneration().then<void>((_) {}, onError: (_, _) {}));
      rethrow;
    }
    final comparison = compareGroupAccessDecimals(
      immutable.snapshotId,
      _replacementSnapshotHighWater,
    );
    if (comparison > 0) {
      _replacementSnapshotHighWater = immutable.snapshotId;
      _replacementSnapshotAtHighWater = immutable;
    }
    for (final entry in immutable.entries.values) {
      final highWater = _entryVersionHighWater[entry.conversationId];
      if (highWater == null ||
          compareGroupAccessDecimals(entry.accessVersion, highWater) > 0) {
        _entryVersionHighWater[entry.conversationId] = entry.accessVersion;
        _entryAtVersionHighWater[entry.conversationId] = entry;
      }
    }
    _ready = false;
    final cleanup = _advanceGeneration();
    return GroupMemberAccessReplacement._(
      registry: this,
      generation: _generation,
      snapshot: immutable,
      cleanup: cleanup,
      immediatelyClean:
          _pendingInvalidationCallbacks.isEmpty &&
          _cleanupPending == 0 &&
          _cleanupFailure == null,
    );
  }

  void _validateReplacement(GroupMemberAccessSnapshot snapshot) {
    if (normalizeGroupAccessPositiveDecimal(snapshot.snapshotId).isEmpty) {
      throw const FormatException('群访问 snapshot high-water 无效');
    }
    final snapshotComparison = compareGroupAccessDecimals(
      snapshot.snapshotId,
      _replacementSnapshotHighWater,
    );
    if (snapshotComparison < 0) {
      throw StateError('群访问 snapshot 回退已拒绝');
    }
    if (snapshotComparison == 0 &&
        _replacementSnapshotAtHighWater != null &&
        !_sameGroupAccessSnapshot(snapshot, _replacementSnapshotAtHighWater!)) {
      throw StateError('同一群访问 snapshot 内容不一致');
    }
    for (final item in snapshot.entries.entries) {
      final entry = item.value;
      if (item.key != entry.conversationId ||
          entry.accessState == GroupMemberAccessState.revoked ||
          normalizeGroupAccessPositiveDecimal(entry.accessVersion).isEmpty) {
        throw const FormatException('群访问 replacement entry 无效');
      }
      final highWater = _entryVersionHighWater[entry.conversationId];
      if (highWater != null &&
          compareGroupAccessDecimals(entry.accessVersion, highWater) < 0) {
        throw StateError('群访问 entry version 回退已拒绝');
      }
      if (highWater == entry.accessVersion) {
        final previous = _entryAtVersionHighWater[entry.conversationId];
        if (previous != null && !_sameGroupAccessEntry(entry, previous)) {
          throw StateError('同一群访问 entry version 内容不一致');
        }
      }
    }
  }

  void commitReplacement(GroupMemberAccessReplacement replacement) {
    if (!identical(replacement.registry, this) ||
        replacement.generation != _generation ||
        _cleanupPending != 0 ||
        _cleanupFailure != null) {
      throw StateError('群访问清理门禁尚未完成或 replacement 已失效');
    }
    _snapshot = replacement.snapshot;
    _ready = true;
  }

  Future<void> replace(GroupMemberAccessSnapshot snapshot) {
    final replacement = beginReplacement(snapshot);
    if (replacement.immediatelyClean) {
      commitReplacement(replacement);
      return Future<void>.value();
    }
    return replacement.cleanup.then((_) {
      commitReplacement(replacement);
    });
  }

  GroupMemberAccessEventProjection project(GroupMemberAccessChanged event) =>
      _snapshot == null
      ? const GroupMemberAccessEventProjection(
          GroupMemberAccessEventDecision.reload,
          null,
        )
      : projectGroupMemberAccessEvent(_snapshot!, event, _seenEventIds);

  void remember(String eventId) {
    _seenEventIds.add(eventId);
    while (_seenEventIds.length > 2048) {
      _seenEventIds.remove(_seenEventIds.first);
    }
  }

  GroupMemberAccessInvalidationRegistration _registerInvalidationCallback(
    int generation,
    GroupMemberAccessInvalidationCallback callback,
  ) {
    if (!isReady || generation != _generation) {
      throw StateError('群访问 epoch 已失效，不能登记清理任务');
    }
    final id = ++_nextInvalidationCallbackId;
    (_invalidationCallbacks[generation] ??= {})[id] = callback;
    return GroupMemberAccessInvalidationRegistration._(this, generation, id);
  }

  void _removeInvalidationCallback(int generation, int id) {
    final callbacks = _invalidationCallbacks[generation];
    callbacks?.remove(id);
    if (callbacks?.isEmpty ?? false) {
      _invalidationCallbacks.remove(generation);
    }
    _pendingInvalidationCallbacks.remove(id);
  }

  Future<void> _advanceGeneration() {
    final callbacks = _invalidationCallbacks.remove(_generation);
    if (callbacks != null) {
      _pendingInvalidationCallbacks.addAll(callbacks);
    }
    if (!_generationInvalidation.isCompleted) {
      _generationInvalidation.complete();
    }
    _generationInvalidation = Completer<void>();
    _generation += 1;
    if (_pendingInvalidationCallbacks.isEmpty && _cleanupPending == 0) {
      _cleanupFailure = null;
      return Future<void>.value();
    }
    final active = _activeCleanup;
    if (active != null) return active;
    final attempt = _runCleanupPass();
    _activeCleanup = attempt;
    unawaited(
      attempt.then<void>(
        (_) {
          if (identical(_activeCleanup, attempt)) _activeCleanup = null;
        },
        onError: (_, _) {
          if (identical(_activeCleanup, attempt)) _activeCleanup = null;
        },
      ),
    );
    return attempt;
  }

  Future<void> _runCleanupPass() async {
    if (_pendingInvalidationCallbacks.isEmpty) {
      _cleanupFailure = null;
      return;
    }
    _cleanupFailure = null;
    final callbacks = Map<int, GroupMemberAccessInvalidationCallback>.of(
      _pendingInvalidationCallbacks,
    );
    Object? firstError;
    StackTrace? firstStackTrace;
    await Future.wait<void>(
      callbacks.entries.map((item) async {
        _cleanupPending += 1;
        try {
          await item.value();
          _pendingInvalidationCallbacks.remove(item.key);
        } on Object catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        } finally {
          _cleanupPending -= 1;
        }
      }),
      eagerError: false,
    );
    if (firstError != null) {
      _cleanupFailure = firstError;
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
    if (_pendingInvalidationCallbacks.isEmpty) _cleanupFailure = null;
  }
}

Map<String, Object?> _strictMap(Object? value, String field) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$field 必须是 string-key object');
  }
  return value.cast<String, Object?>();
}
