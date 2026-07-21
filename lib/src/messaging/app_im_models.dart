import 'package:b8im_app_flutter/src/messaging/contact_display_label.dart';
import 'package:b8im_app_flutter/src/im/group_member_access.dart';

const Object _notProvided = Object();

enum AppImDeliveryStatus {
  sent,
  delivered,
  read;

  static AppImDeliveryStatus parse(String value, String field) {
    return switch (value) {
      'sent' => sent,
      'delivered' => delivered,
      'read' => read,
      _ => throw FormatException('$field 格式无效'),
    };
  }

  int get rank => switch (this) {
    sent => 1,
    delivered => 2,
    read => 3,
  };

  String get label => switch (this) {
    sent => '已发送',
    delivered => '已送达',
    read => '已读',
  };
}

bool appImSameIdentity(
  int leftOrganization,
  String leftUserId,
  int rightOrganization,
  String rightUserId,
) =>
    leftOrganization > 0 &&
    rightOrganization > 0 &&
    leftOrganization == rightOrganization &&
    leftUserId.trim().isNotEmpty &&
    leftUserId.trim() == rightUserId.trim();

enum AppImEventDirection {
  peerReadsCurrent,
  currentReadsPeer,
  groupMember,
  invalid,
}

enum AppImChangeSequenceDecision { apply, stale, gap, invalid }

AppImChangeSequenceDecision classifyAppImChangeSequence({
  required int lastConversationSequence,
  required int lastMessageSequence,
  required int incomingSequence,
}) {
  if (incomingSequence <= 0) return AppImChangeSequenceDecision.invalid;
  if (incomingSequence <= lastConversationSequence ||
      incomingSequence <= lastMessageSequence) {
    return AppImChangeSequenceDecision.stale;
  }
  return incomingSequence == lastConversationSequence + 1
      ? AppImChangeSequenceDecision.apply
      : AppImChangeSequenceDecision.gap;
}

String normalizeAppImAccessSnapshotId(Object? value) {
  if (value is! String || !RegExp(r'^(0|[1-9][0-9]{0,19})$').hasMatch(value)) {
    return '';
  }
  return value;
}

int compareAppImAccessSnapshotIds(String left, String right) {
  final normalizedLeft = normalizeAppImAccessSnapshotId(left);
  final normalizedRight = normalizeAppImAccessSnapshotId(right);
  if (normalizedLeft.isEmpty || normalizedRight.isEmpty) {
    throw const FormatException('跨机构访问快照 ID 格式无效');
  }
  return BigInt.parse(normalizedLeft).compareTo(BigInt.parse(normalizedRight));
}

enum AppImAccessSnapshotObservation { fresh, duplicate, stale, invalid }

final class AppImAccessSnapshotTracker {
  AppImAccessSnapshotTracker(String initialSnapshotId) {
    _latestSnapshotId = normalizeAppImAccessSnapshotId(initialSnapshotId);
    if (_latestSnapshotId != '0') {
      _highestPositiveSnapshotId = _latestSnapshotId;
    }
  }

  late String _latestSnapshotId;
  String _highestPositiveSnapshotId = '';

  String get latestSnapshotId => _latestSnapshotId;
  String get highestPositiveSnapshotId => _highestPositiveSnapshotId;
  bool get isCrossOrganizationFailClosed =>
      _latestSnapshotId.isEmpty || _latestSnapshotId == '0';

  AppImAccessSnapshotObservation reset(Object? value) {
    final snapshotId = normalizeAppImAccessSnapshotId(value);
    if (snapshotId.isEmpty) return AppImAccessSnapshotObservation.invalid;
    if (snapshotId == '0') {
      final duplicated = _latestSnapshotId == '0';
      _latestSnapshotId = '0';
      return duplicated
          ? AppImAccessSnapshotObservation.duplicate
          : AppImAccessSnapshotObservation.fresh;
    }
    return _observePositive(snapshotId, replacingConnectionSnapshot: true);
  }

  AppImAccessSnapshotObservation observe(Object? value) {
    final snapshotId = normalizeAppImAccessSnapshotId(value);
    if (snapshotId.isEmpty) return AppImAccessSnapshotObservation.invalid;
    if (snapshotId == '0') {
      return AppImAccessSnapshotObservation.invalid;
    }
    return _observePositive(snapshotId, replacingConnectionSnapshot: false);
  }

  AppImAccessSnapshotObservation _observePositive(
    String snapshotId, {
    required bool replacingConnectionSnapshot,
  }) {
    if (_highestPositiveSnapshotId.isNotEmpty) {
      final comparison = compareAppImAccessSnapshotIds(
        snapshotId,
        _highestPositiveSnapshotId,
      );
      if (comparison < 0 || (_latestSnapshotId == '0' && comparison == 0)) {
        return AppImAccessSnapshotObservation.stale;
      }
      if (comparison == 0) {
        return AppImAccessSnapshotObservation.duplicate;
      }
    } else if (!replacingConnectionSnapshot &&
        _latestSnapshotId.isNotEmpty &&
        _latestSnapshotId != '0') {
      final comparison = compareAppImAccessSnapshotIds(
        snapshotId,
        _latestSnapshotId,
      );
      if (comparison < 0) return AppImAccessSnapshotObservation.stale;
      if (comparison == 0) return AppImAccessSnapshotObservation.duplicate;
    }
    _latestSnapshotId = snapshotId;
    _highestPositiveSnapshotId = snapshotId;
    return AppImAccessSnapshotObservation.fresh;
  }
}

enum AppImAccessEventDecision {
  apply,
  duplicateEvent,
  staleSnapshot,
  invalidSnapshot,
}

final class AppImAccessEventGate {
  AppImAccessEventGate(String initialSnapshotId)
    : snapshots = AppImAccessSnapshotTracker(initialSnapshotId);

  final AppImAccessSnapshotTracker snapshots;
  final Set<String> _seenEventIds = {};

  bool get isCrossOrganizationFailClosed =>
      snapshots.isCrossOrganizationFailClosed;

  AppImAccessSnapshotObservation resetSnapshot(Object? value) =>
      snapshots.reset(value);

  AppImAccessSnapshotObservation reconcileConnectionSnapshot({
    required Object? current,
    required Object? highestPositive,
  }) {
    final normalizedHighest = normalizeAppImAccessSnapshotId(highestPositive);
    if (normalizedHighest.isEmpty) {
      return AppImAccessSnapshotObservation.invalid;
    }
    if (normalizedHighest != '0') {
      final highObservation = snapshots.observe(normalizedHighest);
      if (highObservation == AppImAccessSnapshotObservation.invalid) {
        return highObservation;
      }
    }
    final normalizedCurrent = normalizeAppImAccessSnapshotId(current);
    if (normalizedCurrent.isEmpty) {
      return AppImAccessSnapshotObservation.invalid;
    }
    if (normalizedCurrent == '0') return snapshots.reset('0');
    return snapshots.reset(normalizedCurrent);
  }

  AppImAccessEventDecision observe(AppImConversationAccessChanged event) {
    if (_seenEventIds.contains(event.eventId)) {
      return AppImAccessEventDecision.duplicateEvent;
    }
    final snapshot = snapshots.observe(event.snapshotId);
    if (snapshot == AppImAccessSnapshotObservation.invalid) {
      return AppImAccessEventDecision.invalidSnapshot;
    }
    if (snapshot == AppImAccessSnapshotObservation.stale) {
      return AppImAccessEventDecision.staleSnapshot;
    }
    _seenEventIds.add(event.eventId);
    if (_seenEventIds.length > 512) _seenEventIds.remove(_seenEventIds.first);
    return AppImAccessEventDecision.apply;
  }
}

final class AppImConversationAccessChanged {
  const AppImConversationAccessChanged({
    required this.eventId,
    required this.snapshotId,
    required this.conversationId,
    required this.allowed,
    required this.targetOrganization,
    required this.targetUserId,
    required this.peerOrganization,
    required this.peerUserId,
  });

  factory AppImConversationAccessChanged.fromJson(
    Object? value, {
    required int expectedOrganization,
    required String expectedUserId,
  }) {
    final map = imMap(value, 'conversation.access_changed.data');
    final eventId = imString(
      map,
      'event_id',
      'conversation.access_changed.event_id',
    );
    final snapshotId = normalizeAppImAccessSnapshotId(
      map['cross_org_access_snapshot_id'],
    );
    final targetOrganization = imInt(
      map,
      'target_organization',
      'conversation.access_changed.target_organization',
    );
    final targetUserId = imString(
      map,
      'target_user_id',
      'conversation.access_changed.target_user_id',
    );
    final peerOrganization = imInt(
      map,
      'peer_organization',
      'conversation.access_changed.peer_organization',
    );
    final peerUserId = imString(
      map,
      'peer_user_id',
      'conversation.access_changed.peer_user_id',
    );
    if (map['event_type'] != 'conversation.access_changed' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(eventId) ||
        map['conversation_type'] != 1 ||
        snapshotId.isEmpty ||
        snapshotId == '0' ||
        map['allowed'] is! bool ||
        targetOrganization != expectedOrganization ||
        targetUserId != expectedUserId.trim() ||
        peerOrganization <= 0 ||
        peerOrganization == expectedOrganization ||
        peerUserId.isEmpty) {
      throw const FormatException('conversation.access_changed 事件协议无效');
    }
    return AppImConversationAccessChanged(
      eventId: eventId,
      snapshotId: snapshotId,
      conversationId: imString(
        map,
        'conversation_id',
        'conversation.access_changed.conversation_id',
      ),
      allowed: map['allowed'] as bool,
      targetOrganization: targetOrganization,
      targetUserId: targetUserId,
      peerOrganization: peerOrganization,
      peerUserId: peerUserId,
    );
  }

  final String eventId;
  final String snapshotId;
  final String conversationId;
  final bool allowed;
  final int targetOrganization;
  final String targetUserId;
  final int peerOrganization;
  final String peerUserId;
}

final class AppImConversationIdentityContext {
  const AppImConversationIdentityContext({
    required this.organization,
    required this.userId,
    required this.conversationId,
    required this.conversationType,
    required this.peerOrganization,
    required this.peerUserId,
  });

  final int organization;
  final String userId;
  final String conversationId;
  final int conversationType;
  final int? peerOrganization;
  final String? peerUserId;

  bool get isCrossOrganization =>
      conversationType == 1 &&
      peerOrganization != null &&
      peerOrganization != organization;

  bool isParticipant(int actorOrganization, String actorUserId) {
    if (conversationType == 2) {
      return actorOrganization == organization && actorUserId.trim().isNotEmpty;
    }
    return appImSameIdentity(
          actorOrganization,
          actorUserId,
          organization,
          userId,
        ) ||
        appImSameIdentity(
          actorOrganization,
          actorUserId,
          peerOrganization ?? 0,
          peerUserId ?? '',
        );
  }

  bool acceptsMessage(AppImMessage message) {
    if (message.organization != organization ||
        message.conversationId != conversationId ||
        message.conversationType != conversationType) {
      return false;
    }
    if (message.messageType == 5) {
      final actorOrganization = message.content?['actor_organization'];
      final actorUserId = message.content?['actor_user_id'];
      return message.senderOrganization == organization &&
          message.senderId.trim().isNotEmpty &&
          actorOrganization is int &&
          actorUserId is String &&
          isParticipant(actorOrganization, actorUserId);
    }
    return isParticipant(message.senderOrganization, message.senderId);
  }

  AppImEventDirection classifyReceipt(AppImReceipt receipt) {
    if (receipt.conversationId != conversationId) {
      return AppImEventDirection.invalid;
    }
    if (conversationType == 2) {
      return receipt.senderOrganization == organization &&
              receipt.userOrganization == organization
          ? AppImEventDirection.groupMember
          : AppImEventDirection.invalid;
    }
    if (appImSameIdentity(
          receipt.senderOrganization,
          receipt.senderId,
          organization,
          userId,
        ) &&
        appImSameIdentity(
          receipt.userOrganization,
          receipt.userId,
          peerOrganization ?? 0,
          peerUserId ?? '',
        )) {
      return AppImEventDirection.peerReadsCurrent;
    }
    if (appImSameIdentity(
          receipt.senderOrganization,
          receipt.senderId,
          peerOrganization ?? 0,
          peerUserId ?? '',
        ) &&
        appImSameIdentity(
          receipt.userOrganization,
          receipt.userId,
          organization,
          userId,
        )) {
      return AppImEventDirection.currentReadsPeer;
    }
    return AppImEventDirection.invalid;
  }

  AppImEventDirection classifyConversationRead(
    AppImConversationReadState read,
  ) {
    if (read.conversationId != conversationId) {
      return AppImEventDirection.invalid;
    }
    if (conversationType == 2) {
      return read.userOrganization == organization
          ? AppImEventDirection.groupMember
          : AppImEventDirection.invalid;
    }
    if (appImSameIdentity(
      read.userOrganization,
      read.userId,
      organization,
      userId,
    )) {
      return AppImEventDirection.currentReadsPeer;
    }
    return appImSameIdentity(
          read.userOrganization,
          read.userId,
          peerOrganization ?? 0,
          peerUserId ?? '',
        )
        ? AppImEventDirection.peerReadsCurrent
        : AppImEventDirection.invalid;
  }

  bool acceptsMutation(AppImMessageMutation mutation, AppImMessage original) {
    if (!isParticipant(mutation.actorOrganization, mutation.actorUserId) ||
        mutation.conversationId != original.conversationId ||
        mutation.messageId != original.messageId ||
        mutation.messageSeq != original.messageSeq) {
      return false;
    }
    final actorIsSender = appImSameIdentity(
      mutation.actorOrganization,
      mutation.actorUserId,
      original.senderOrganization,
      original.senderId,
    );
    if (mutation.command == 'recall') {
      return actorIsSender && mutation.status == 'recalled';
    }
    if (mutation.command == 'edit') {
      final edited = mutation.message;
      return actorIsSender &&
          original.messageType == 1 &&
          edited != null &&
          appImSameIdentity(
            edited.senderOrganization,
            edited.senderId,
            original.senderOrganization,
            original.senderId,
          ) &&
          acceptsMessage(edited);
    }
    if (mutation.scope == 'both') {
      return actorIsSender &&
          mutation.targetOrganization == null &&
          mutation.targetUserId == null;
    }
    return mutation.scope == 'self' &&
        appImSameIdentity(
          mutation.actorOrganization,
          mutation.actorUserId,
          organization,
          userId,
        ) &&
        appImSameIdentity(
          mutation.targetOrganization ?? 0,
          mutation.targetUserId ?? '',
          organization,
          userId,
        );
  }

  bool acceptsSyncedChange(
    AppImSyncedMessageChange change,
    AppImMessage? original,
  ) {
    if (!isParticipant(change.actorOrganization, change.actorUserId) ||
        change.conversationId != conversationId ||
        (original != null &&
            (original.conversationId != change.conversationId ||
                original.messageId != change.messageId ||
                original.messageSeq != change.messageSeq))) {
      return false;
    }
    if (change.changeType == 'delete_self') {
      return appImSameIdentity(
            change.actorOrganization,
            change.actorUserId,
            organization,
            userId,
          ) &&
          appImSameIdentity(
            change.targetOrganization ?? 0,
            change.targetUserId ?? '',
            organization,
            userId,
          );
    }
    if (original == null ||
        !appImSameIdentity(
          change.actorOrganization,
          change.actorUserId,
          original.senderOrganization,
          original.senderId,
        ) ||
        change.targetOrganization != null ||
        change.targetUserId != null) {
      return false;
    }
    return switch (change.changeType) {
      'edit' => original.messageType == 1,
      'recall' || 'delete_both' => true,
      _ => false,
    };
  }
}

final class AppImReceipt {
  const AppImReceipt({
    required this.messageId,
    required this.conversationId,
    required this.messageSeq,
    required this.senderOrganization,
    required this.senderId,
    required this.userOrganization,
    required this.userId,
    required this.status,
    required this.time,
  });

  factory AppImReceipt.fromJson(Object? value, String field) {
    final map = imMap(value, field);
    final sequence = imInt(map, 'message_seq', '$field.message_seq');
    final senderOrganization = imInt(
      map,
      'sender_organization',
      '$field.sender_organization',
    );
    final userOrganization = imInt(
      map,
      'user_organization',
      '$field.user_organization',
    );
    if (sequence <= 0 || senderOrganization <= 0 || userOrganization <= 0) {
      throw FormatException('$field 复合身份或 message_seq 格式无效');
    }
    final status = AppImDeliveryStatus.parse(
      imString(map, 'status', '$field.status'),
      '$field.status',
    );
    if (status == AppImDeliveryStatus.sent) {
      throw FormatException('$field.status 只允许 delivered 或 read');
    }
    return AppImReceipt(
      messageId: imString(map, 'message_id', '$field.message_id'),
      conversationId: imString(
        map,
        'conversation_id',
        '$field.conversation_id',
      ),
      messageSeq: sequence,
      senderOrganization: senderOrganization,
      senderId: imString(map, 'sender_id', '$field.sender_id'),
      userOrganization: userOrganization,
      userId: imString(map, 'user_id', '$field.user_id'),
      status: status,
      time: imString(map, 'time', '$field.time'),
    );
  }

  final String messageId;
  final String conversationId;
  final int messageSeq;
  final int senderOrganization;
  final String senderId;
  final int userOrganization;
  final String userId;
  final AppImDeliveryStatus status;
  final String time;
}

final class AppImConversationReadState {
  const AppImConversationReadState({
    required this.conversationId,
    required this.lastReadMessageId,
    required this.lastReadSeq,
    required this.unreadCount,
    required this.userOrganization,
    required this.userId,
    required this.time,
  });

  factory AppImConversationReadState.fromJson(Object? value, String field) {
    final map = imMap(value, field);
    final sequence = imInt(map, 'last_read_seq', '$field.last_read_seq');
    final unread = imInt(map, 'unread_count', '$field.unread_count');
    final userOrganization = imInt(
      map,
      'user_organization',
      '$field.user_organization',
    );
    if (sequence <= 0 || unread < 0 || userOrganization <= 0) {
      throw FormatException('$field 游标或未读数无效');
    }
    return AppImConversationReadState(
      conversationId: imString(
        map,
        'conversation_id',
        '$field.conversation_id',
      ),
      lastReadMessageId: imString(
        map,
        'last_read_message_id',
        '$field.last_read_message_id',
      ),
      lastReadSeq: sequence,
      unreadCount: unread,
      userOrganization: userOrganization,
      userId: imString(map, 'user_id', '$field.user_id'),
      time: imString(map, 'time', '$field.time'),
    );
  }

  final String conversationId;
  final String lastReadMessageId;
  final int lastReadSeq;
  final int unreadCount;
  final int userOrganization;
  final String userId;
  final String time;
}

final class AppImTypingState {
  const AppImTypingState({
    required this.conversationId,
    required this.actorOrganization,
    required this.actorUserId,
    required this.username,
  });

  factory AppImTypingState.fromJson(Object? value) {
    final map = imMap(value, 'typing.data');
    final actorOrganization = imInt(
      map,
      'actor_organization',
      'typing.actor_organization',
    );
    if (actorOrganization <= 0) {
      throw const FormatException('typing.actor_organization 无效');
    }
    return AppImTypingState(
      conversationId: imString(
        map,
        'conversation_id',
        'typing.conversation_id',
      ),
      actorOrganization: actorOrganization,
      actorUserId: imString(map, 'actor_user_id', 'typing.actor_user_id'),
      username: imString(map, 'username', 'typing.username', allowEmpty: true),
    );
  }

  final String conversationId;
  final int actorOrganization;
  final String actorUserId;
  final String username;
}

final class AppImMessageMutation {
  const AppImMessageMutation({
    required this.command,
    required this.eventId,
    required this.eventType,
    required this.conversationId,
    required this.messageId,
    required this.messageSeq,
    required this.changeSeq,
    required this.actorOrganization,
    required this.actorUserId,
    required this.targetOrganization,
    required this.targetUserId,
    required this.scope,
    required this.status,
    required this.message,
  });

  factory AppImMessageMutation.fromJson(
    String command,
    Object? value,
    int expectedOrganization,
  ) {
    if (!const {'recall', 'edit', 'delete'}.contains(command)) {
      throw const FormatException('消息变更 command 无效');
    }
    final field = '$command.data';
    final map = imMap(value, field);
    final eventId = imString(map, 'event_id', '$field.event_id');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(eventId)) {
      throw FormatException('$field.event_id 无效');
    }
    final eventType = imString(map, 'event_type', '$field.event_type');
    final expectedEventType = switch (command) {
      'recall' => 'message.recalled',
      'edit' => 'message.edited',
      _ => null,
    };
    if ((expectedEventType != null && eventType != expectedEventType) ||
        (command == 'delete' &&
            !const {
              'message.deleted_both',
              'message.deleted_self',
            }.contains(eventType))) {
      throw FormatException('$field.event_type 与 command 不一致');
    }
    final messageSeq = imInt(map, 'message_seq', '$field.message_seq');
    final changeSeq = imInt(map, 'change_seq', '$field.change_seq');
    final actorOrganization = imInt(
      map,
      'actor_organization',
      '$field.actor_organization',
    );
    final actorUserId = imString(map, 'actor_user_id', '$field.actor_user_id');
    if (messageSeq <= 0 || changeSeq <= 0 || actorOrganization <= 0) {
      throw FormatException('$field 序号或 actor 复合身份无效');
    }

    final rawTargetOrganization = map['target_organization'];
    final rawTargetUserId = map['target_user_id'];
    if ((rawTargetOrganization == null) != (rawTargetUserId == null)) {
      throw FormatException('$field target 复合身份不完整');
    }
    final int? targetOrganization;
    if (rawTargetOrganization == null) {
      targetOrganization = null;
    } else if (rawTargetOrganization is int && rawTargetOrganization > 0) {
      targetOrganization = rawTargetOrganization;
    } else {
      throw FormatException('$field.target_organization 无效');
    }
    final String? targetUserId;
    if (rawTargetUserId == null) {
      targetUserId = null;
    } else if (rawTargetUserId is String && rawTargetUserId.trim().isNotEmpty) {
      targetUserId = rawTargetUserId.trim();
    } else {
      throw FormatException('$field.target_user_id 无效');
    }
    final scope = map['scope'] is String ? (map['scope'] as String).trim() : '';
    final status = map['status'] is String
        ? (map['status'] as String).trim()
        : '';
    final message = command == 'edit'
        ? AppImMessage.fromRealtime(map['message'])
        : null;
    if (command == 'recall' &&
        (status != 'recalled' || targetOrganization != null)) {
      throw FormatException('$field recall schema 无效');
    }
    if (command == 'edit' &&
        (message == null ||
            targetOrganization != null ||
            message.organization != expectedOrganization ||
            message.conversationId != map['conversation_id'] ||
            message.messageId != map['message_id'] ||
            message.messageSeq != messageSeq ||
            message.senderOrganization != actorOrganization ||
            message.senderId != actorUserId)) {
      throw FormatException('$field edit schema 或复合身份无效');
    }
    if (command == 'delete') {
      final self = eventType == 'message.deleted_self';
      if ((self &&
              (scope != 'self' ||
                  targetOrganization == null ||
                  targetUserId == null)) ||
          (!self &&
              (scope != 'both' ||
                  status != 'deleted_both' ||
                  targetOrganization != null))) {
        throw FormatException('$field delete schema 无效');
      }
    }

    return AppImMessageMutation(
      command: command,
      eventId: eventId,
      eventType: eventType,
      conversationId: imString(
        map,
        'conversation_id',
        '$field.conversation_id',
      ),
      messageId: imString(map, 'message_id', '$field.message_id'),
      messageSeq: messageSeq,
      changeSeq: changeSeq,
      actorOrganization: actorOrganization,
      actorUserId: actorUserId,
      targetOrganization: targetOrganization,
      targetUserId: targetUserId,
      scope: scope,
      status: status,
      message: message,
    );
  }

  final String command;
  final String eventId;
  final String eventType;
  final String conversationId;
  final String messageId;
  final int messageSeq;
  final int changeSeq;
  final int actorOrganization;
  final String actorUserId;
  final int? targetOrganization;
  final String? targetUserId;
  final String scope;
  final String status;
  final AppImMessage? message;
}

final class AppImMutationResult {
  const AppImMutationResult({
    required this.command,
    required this.conversationId,
    required this.messageId,
    required this.messageSeq,
    required this.changeSeq,
    required this.scope,
    required this.status,
    required this.message,
  });

  final String command;
  final String conversationId;
  final String messageId;
  final int messageSeq;
  final int changeSeq;
  final String scope;
  final String status;
  final AppImMessage? message;
}

final class AppImSyncedMessageChange {
  const AppImSyncedMessageChange({
    required this.conversationId,
    required this.changeSeq,
    required this.changeType,
    required this.messageId,
    required this.messageSeq,
    required this.actorOrganization,
    required this.actorUserId,
    required this.targetOrganization,
    required this.targetUserId,
    required this.payload,
    required this.createTime,
  });

  factory AppImSyncedMessageChange.fromJson(
    Object? value, {
    required AppImConversationIdentityContext identity,
  }) {
    final map = imMap(value, 'conversation sync change');
    final conversationId = imString(
      map,
      'conversation_id',
      'conversation sync change.conversation_id',
    );
    final changeType = imString(
      map,
      'change_type',
      'conversation sync change.change_type',
    );
    final changeSeq = imInt(
      map,
      'change_seq',
      'conversation sync change.change_seq',
    );
    final messageSeq = imInt(
      map,
      'message_seq',
      'conversation sync change.message_seq',
    );
    final actorOrganization = imInt(
      map,
      'actor_organization',
      'conversation sync change.actor_organization',
    );
    final actorUserId = imString(
      map,
      'actor_user_id',
      'conversation sync change.actor_user_id',
    );
    if (conversationId != identity.conversationId ||
        !const {
          'recall',
          'edit',
          'delete_both',
          'delete_self',
        }.contains(changeType) ||
        changeSeq <= 0 ||
        messageSeq <= 0 ||
        actorOrganization <= 0 ||
        !identity.isParticipant(actorOrganization, actorUserId)) {
      throw const FormatException('conversation sync change 基础字段无效');
    }

    final rawTargetOrganization = map['target_organization'];
    final rawTargetUserId = map['target_user_id'];
    if ((rawTargetOrganization == null) != (rawTargetUserId == null)) {
      throw const FormatException('conversation sync change target 复合身份不完整');
    }
    final int? targetOrganization;
    final String? targetUserId;
    if (rawTargetOrganization == null) {
      targetOrganization = null;
      targetUserId = null;
    } else if (rawTargetOrganization is int &&
        rawTargetOrganization > 0 &&
        rawTargetUserId is String &&
        rawTargetUserId.trim().isNotEmpty &&
        appImSameIdentity(
          rawTargetOrganization,
          rawTargetUserId,
          identity.organization,
          identity.userId,
        )) {
      targetOrganization = rawTargetOrganization;
      targetUserId = rawTargetUserId.trim();
    } else {
      throw const FormatException('conversation sync change target 复合身份无效');
    }

    final payload = imMap(map['payload'], 'conversation sync change.payload');
    if (changeType == 'recall' &&
        (targetOrganization != null || payload['status'] != 'recalled')) {
      throw const FormatException('conversation sync recall payload 无效');
    }
    if (changeType == 'edit') {
      final content = payload['content'];
      final editTime = payload['edit_time'];
      final editCount = payload['edit_count'];
      if (targetOrganization != null ||
          content is! Map ||
          content['text'] is! String ||
          (content['text'] as String).trim().isEmpty ||
          editTime is! String ||
          editTime.trim().isEmpty ||
          editCount is! int ||
          editCount <= 0) {
        throw const FormatException('conversation sync edit payload 无效');
      }
    }
    if (changeType == 'delete_both' &&
        (targetOrganization != null ||
            payload['scope'] != 'both' ||
            payload['status'] != 'deleted_both')) {
      throw const FormatException('conversation sync delete_both payload 无效');
    }
    if (changeType == 'delete_self' &&
        (targetOrganization == null || payload['scope'] != 'self')) {
      throw const FormatException('conversation sync delete_self payload 无效');
    }

    return AppImSyncedMessageChange(
      conversationId: conversationId,
      changeSeq: changeSeq,
      changeType: changeType,
      messageId: imString(
        map,
        'message_id',
        'conversation sync change.message_id',
      ),
      messageSeq: messageSeq,
      actorOrganization: actorOrganization,
      actorUserId: actorUserId,
      targetOrganization: targetOrganization,
      targetUserId: targetUserId,
      payload: Map.unmodifiable(payload),
      createTime: imString(
        map,
        'create_time',
        'conversation sync change.create_time',
      ),
    );
  }

  final String conversationId;
  final int changeSeq;
  final String changeType;
  final String messageId;
  final int messageSeq;
  final int actorOrganization;
  final String actorUserId;
  final int? targetOrganization;
  final String? targetUserId;
  final Map<String, Object?> payload;
  final String createTime;
}

final class AppImConversationSyncPage {
  const AppImConversationSyncPage({
    required this.conversationId,
    required this.messages,
    required this.changes,
    required this.nextAfterMessageSeq,
    required this.nextAfterChangeSeq,
    required this.messagesHasMore,
    required this.changesHasMore,
    required this.crossOrgAccessSnapshotId,
    required this.groupAccessSnapshotId,
    required this.groupAccessVersion,
    required this.groupAccessState,
  });

  factory AppImConversationSyncPage.fromJson(
    Object? value, {
    required AppImConversationIdentityContext identity,
  }) {
    final map = imMap(value, 'conversation sync');
    final rawMessages = map['messages'];
    final rawChanges = map['changes'];
    if (map['organization'] != identity.organization ||
        map['scope'] != 'conversation' ||
        map['conversation_id'] != identity.conversationId ||
        rawMessages is! List ||
        rawChanges is! List) {
      throw const FormatException('conversation SYNC_ACK 格式无效');
    }
    final snapshotId = normalizeAppImAccessSnapshotId(
      map['cross_org_access_snapshot_id'],
    );
    if (snapshotId.isEmpty) {
      throw const FormatException(
        'conversation SYNC_ACK cross_org_access_snapshot_id 无效',
      );
    }
    final groupSnapshotId = normalizeGroupAccessPositiveDecimal(
      map['access_snapshot_id'],
    );
    if (groupSnapshotId.isEmpty) {
      throw const FormatException(
        'conversation SYNC_ACK access_snapshot_id 无效',
      );
    }
    final groupVersion = identity.conversationType == 2
        ? normalizeGroupAccessPositiveDecimal(map['access_version'])
        : '';
    final groupState = identity.conversationType == 2
        ? map['access_state']
        : null;
    if ((identity.conversationType == 2 &&
            (groupVersion.isEmpty ||
                (groupState != 'active' && groupState != 'history_only'))) ||
        (identity.conversationType != 2 &&
            (map.containsKey('access_version') ||
                map.containsKey('access_state')))) {
      throw const FormatException('conversation SYNC_ACK 群访问 entry 无效');
    }
    final nextAfterMessageSeq = imInt(
      map,
      'next_after_seq',
      'conversation sync.next_after_seq',
    );
    final nextAfterChangeSeq = imInt(
      map,
      'next_after_change_seq',
      'conversation sync.next_after_change_seq',
    );
    if (nextAfterMessageSeq < 0 || nextAfterChangeSeq < 0) {
      throw const FormatException('conversation SYNC_ACK 游标无效');
    }
    return AppImConversationSyncPage(
      conversationId: identity.conversationId,
      messages: rawMessages
          .map(AppImMessage.fromRealtime)
          .toList(growable: false),
      changes: rawChanges
          .map(
            (item) =>
                AppImSyncedMessageChange.fromJson(item, identity: identity),
          )
          .toList(growable: false),
      nextAfterMessageSeq: nextAfterMessageSeq,
      nextAfterChangeSeq: nextAfterChangeSeq,
      messagesHasMore: imBool(
        map,
        'messages_has_more',
        'conversation sync.messages_has_more',
      ),
      changesHasMore: imBool(
        map,
        'changes_has_more',
        'conversation sync.changes_has_more',
      ),
      crossOrgAccessSnapshotId: snapshotId,
      groupAccessSnapshotId: groupSnapshotId,
      groupAccessVersion: groupVersion,
      groupAccessState: groupState as String?,
    );
  }

  final String conversationId;
  final List<AppImMessage> messages;
  final List<AppImSyncedMessageChange> changes;
  final int nextAfterMessageSeq;
  final int nextAfterChangeSeq;
  final bool messagesHasMore;
  final bool changesHasMore;
  final String crossOrgAccessSnapshotId;
  final String groupAccessSnapshotId;
  final String groupAccessVersion;
  final String? groupAccessState;
}

final class AppImUserSummary {
  const AppImUserSummary({
    required this.userId,
    required this.account,
    required this.nickname,
    required this.avatarUrl,
    required this.organization,
    this.companyName = '',
    this.isCrossOrganization = false,
    this.displayNameOverride = '',
  });

  factory AppImUserSummary.fromJson(Object? value, String field) {
    final map = imMap(value, field);
    final nickname = imString(
      map,
      'nickname',
      '$field.nickname',
      allowEmpty: true,
    );
    final account = imString(
      map,
      'account',
      '$field.account',
      allowEmpty: true,
    );
    final companyName = imString(
      map,
      'company_name',
      '$field.company_name',
      allowEmpty: true,
    );
    final organizationName = imString(
      map,
      'organization_name',
      '$field.organization_name',
      allowEmpty: true,
    );
    final resolvedCompany = companyName.isNotEmpty
        ? companyName
        : organizationName;
    final isCross =
        map['is_cross_organization'] == true ||
        map['is_cross_organization'] == 1 ||
        map['is_cross_organization'] == '1';
    final serverDisplay = imString(
      map,
      'display_name',
      '$field.display_name',
      allowEmpty: true,
    );
    final organization = _imOptionalInt(map, 'organization');
    if (organization <= 0) {
      throw FormatException('$field.organization 无效');
    }
    return AppImUserSummary(
      userId: imString(map, 'user_id', '$field.user_id'),
      account: account,
      nickname: nickname,
      avatarUrl: imString(
        map,
        'avatar_url',
        '$field.avatar_url',
        allowEmpty: true,
      ),
      organization: organization,
      companyName: resolvedCompany,
      isCrossOrganization: isCross,
      displayNameOverride: serverDisplay,
    );
  }

  final String userId;
  final String account;
  final String nickname;
  final String avatarUrl;
  final int organization;
  final String companyName;
  final bool isCrossOrganization;
  final String displayNameOverride;

  String get displayName => ContactDisplayLabel.format(
    nickname: nickname,
    account: account,
    companyName: companyName,
    isCrossOrganization: isCrossOrganization,
    serverDisplayName: displayNameOverride,
  );
}

final class AppImConversation {
  const AppImConversation({
    required this.conversationId,
    required this.conversationType,
    required this.title,
    required this.peerUser,
    required this.lastMessageId,
    required this.lastMessageSeq,
    required this.lastMessageSummary,
    required this.lastMessageTime,
    required this.unreadCount,
    required this.isPinned,
    required this.isMuted,
    required this.avatarUrl,
    this.isVirtual = false,
  });

  factory AppImConversation.virtualSingle({
    required int organization,
    required String userId,
    required String title,
    required String account,
    required String avatarUrl,
    String companyName = '',
    bool isCrossOrganization = false,
  }) => AppImConversation(
    conversationId: 'virtual:$organization:$userId',
    conversationType: 1,
    title: title,
    peerUser: AppImUserSummary(
      userId: userId,
      account: account,
      nickname: title,
      avatarUrl: avatarUrl,
      organization: organization,
      companyName: companyName,
      isCrossOrganization: isCrossOrganization,
    ),
    lastMessageId: '',
    lastMessageSeq: 0,
    lastMessageSummary: '',
    lastMessageTime: '',
    unreadCount: 0,
    isPinned: false,
    isMuted: false,
    avatarUrl: avatarUrl,
    isVirtual: true,
  );

  factory AppImConversation.fromJson(Object? value) {
    final map = imMap(value, 'conversation');
    final type = imInt(map, 'conversation_type', 'conversation_type');
    if (type != 1 && type != 2) {
      throw const FormatException('conversation_type 只允许 1 或 2');
    }
    final rawPeer = map['peer_user'];
    final peer = rawPeer == null
        ? null
        : AppImUserSummary.fromJson(rawPeer, 'peer_user');
    if (type == 1 && peer == null) {
      throw const FormatException('单聊会话缺少 peer_user');
    }
    final lastMessageSeq = imInt(map, 'last_message_seq', 'last_message_seq');
    final unreadCount = imInt(map, 'unread_count', 'unread_count');
    if (lastMessageSeq < 0 || unreadCount < 0) {
      throw const FormatException('会话序号或未读数无效');
    }
    return AppImConversation(
      conversationId: imString(map, 'conversation_id', 'conversation_id'),
      conversationType: type,
      title: imString(map, 'title', 'title'),
      peerUser: peer,
      lastMessageId: imString(
        map,
        'last_message_id',
        'last_message_id',
        allowEmpty: true,
      ),
      lastMessageSeq: lastMessageSeq,
      lastMessageSummary: imString(
        map,
        'last_message_summary',
        'last_message_summary',
        allowEmpty: true,
      ),
      lastMessageTime: imString(
        map,
        'last_message_time',
        'last_message_time',
        allowEmpty: true,
      ),
      unreadCount: unreadCount,
      isPinned: imBool(map, 'is_pinned', 'is_pinned'),
      isMuted: imBool(map, 'is_muted', 'is_muted'),
      avatarUrl: imString(map, 'avatar_url', 'avatar_url', allowEmpty: true),
    );
  }

  final String conversationId;
  final int conversationType;
  final String title;
  final AppImUserSummary? peerUser;
  final String lastMessageId;
  final int lastMessageSeq;
  final String lastMessageSummary;
  final String lastMessageTime;
  final int unreadCount;
  final bool isPinned;
  final bool isMuted;
  final String avatarUrl;
  final bool isVirtual;
}

final class AppImMessage {
  const AppImMessage({
    required this.organization,
    required this.globalSeq,
    required this.conversationId,
    required this.conversationType,
    required this.messageId,
    required this.messageSeq,
    required this.clientMsgId,
    required this.senderOrganization,
    required this.senderId,
    required this.senderUser,
    required this.messageType,
    required this.content,
    required this.status,
    required this.editTime,
    required this.editCount,
    required this.createTime,
    required this.updateTime,
    required this.deliveryStatus,
  });

  factory AppImMessage.fromRealtime(Object? value) {
    final map = imMap(value, 'realtime message');
    final organization = imInt(map, 'organization', 'message.organization');
    if (organization <= 0) {
      throw const FormatException('message.organization 无效');
    }
    final globalSeq = imString(map, 'global_seq', 'message.global_seq');
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(globalSeq)) {
      throw const FormatException('message.global_seq 无效');
    }
    final status = imString(map, 'status', 'message.status');
    if (!const {'normal', 'recalled', 'deleted_both'}.contains(status)) {
      throw const FormatException('实时消息 status 无效');
    }
    final content = _content(map['content'], status, 'realtime message');
    return _fromMap(
      map,
      organization: organization,
      globalSeq: globalSeq,
      status: status,
      content: content,
      deliveryStatus: null,
    );
  }

  factory AppImMessage.fromHttp(Object? value, int expectedOrganization) {
    final map = imMap(value, 'HTTP message');
    final organization = imInt(map, 'organization', 'message.organization');
    if (organization <= 0 || organization != expectedOrganization) {
      throw const FormatException('HTTP message.organization 与当前 home 不一致');
    }
    final rawStatus = imInt(map, 'status', 'message.status');
    final status = switch (rawStatus) {
      1 => 'normal',
      2 => 'recalled',
      3 => 'deleted_both',
      _ => throw const FormatException('HTTP 消息 status 无效'),
    };
    final deliveryStatusValue = imString(
      map,
      'delivery_status',
      'message.delivery_status',
      allowEmpty: true,
    );
    return _fromMap(
      map,
      organization: organization,
      globalSeq: null,
      status: status,
      content: _content(map['content'], status, 'HTTP message'),
      deliveryStatus: deliveryStatusValue.isEmpty
          ? null
          : AppImDeliveryStatus.parse(
              deliveryStatusValue,
              'message.delivery_status',
            ),
    );
  }

  static AppImMessage _fromMap(
    Map<String, Object?> map, {
    required int organization,
    required String? globalSeq,
    required String status,
    required Map<String, Object?>? content,
    required AppImDeliveryStatus? deliveryStatus,
  }) {
    final type = imInt(map, 'conversation_type', 'message.conversation_type');
    final sequence = imInt(map, 'message_seq', 'message.message_seq');
    final messageType = imInt(map, 'message_type', 'message.message_type');
    if ((type != 1 && type != 2) || sequence <= 0 || messageType <= 0) {
      throw const FormatException('消息类型或序号无效');
    }
    _validateMessageContent(messageType, status, content);
    final rawSender = map['sender_user'];
    final senderOrganization = imInt(
      map,
      'sender_organization',
      'message.sender_organization',
    );
    final senderId = imString(map, 'sender_id', 'message.sender_id');
    final senderUser = rawSender == null
        ? null
        : AppImUserSummary.fromJson(rawSender, 'message.sender_user');
    if (senderOrganization <= 0 ||
        (senderUser != null &&
            (senderUser.organization != senderOrganization ||
                senderUser.userId != senderId))) {
      throw const FormatException('消息发送者复合身份无效');
    }
    return AppImMessage(
      organization: organization,
      globalSeq: globalSeq,
      conversationId: imString(
        map,
        'conversation_id',
        'message.conversation_id',
      ),
      conversationType: type,
      messageId: imString(map, 'message_id', 'message.message_id'),
      messageSeq: sequence,
      clientMsgId: imString(map, 'client_msg_id', 'message.client_msg_id'),
      senderOrganization: senderOrganization,
      senderId: senderId,
      senderUser: senderUser,
      messageType: messageType,
      content: content,
      status: status,
      editTime: imString(
        map,
        'edit_time',
        'message.edit_time',
        allowEmpty: true,
      ),
      editCount: imInt(map, 'edit_count', 'message.edit_count'),
      createTime: imString(map, 'create_time', 'message.create_time'),
      updateTime: imString(
        map,
        'update_time',
        'message.update_time',
        allowEmpty: true,
        missingAsEmpty: true,
      ),
      deliveryStatus: deliveryStatus,
    );
  }

  final int organization;
  final String? globalSeq;
  final String conversationId;
  final int conversationType;
  final String messageId;
  final int messageSeq;
  final String clientMsgId;
  final int senderOrganization;
  final String senderId;
  final AppImUserSummary? senderUser;
  final int messageType;
  final Map<String, Object?>? content;
  final String status;
  final String editTime;
  final int editCount;
  final String createTime;
  final String updateTime;
  final AppImDeliveryStatus? deliveryStatus;

  AppImMessage copyWith({
    Object? content = _notProvided,
    String? status,
    String? editTime,
    int? editCount,
    String? updateTime,
    AppImDeliveryStatus? deliveryStatus,
  }) {
    return AppImMessage(
      organization: organization,
      globalSeq: globalSeq,
      conversationId: conversationId,
      conversationType: conversationType,
      messageId: messageId,
      messageSeq: messageSeq,
      clientMsgId: clientMsgId,
      senderOrganization: senderOrganization,
      senderId: senderId,
      senderUser: senderUser,
      messageType: messageType,
      content: identical(content, _notProvided)
          ? this.content
          : content as Map<String, Object?>?,
      status: status ?? this.status,
      editTime: editTime ?? this.editTime,
      editCount: editCount ?? this.editCount,
      createTime: createTime,
      updateTime: updateTime ?? this.updateTime,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
    );
  }

  String get displayText {
    if (status == 'recalled') return '消息已撤回';
    if (status == 'deleted_both') return '消息已删除';
    if (messageType == 2) return '[图片]';
    if (messageType == 3) return content?['name']?.toString() ?? '[文件]';
    if (messageType == 4) return '[语音]';
    if (messageType == 11) return '[视频]';
    if (messageType == 5) {
      final text = content?['text'];
      return text is String && text.isNotEmpty ? text : '[系统通知]';
    }
    if (messageType != 1) return '[暂不支持的消息类型]';
    final text = content?['text'];
    return text is String && text.isNotEmpty ? text : '[空文本]';
  }

  String get assetFileId => content?['file_id']?.toString() ?? '';
  String get assetName => content?['name']?.toString() ?? '';
  int get assetSize {
    final value = content?['size'];
    return value is int ? value : 0;
  }

  String get assetMimeType => content?['mime_type']?.toString() ?? '';
}

final class AppImMessagePage {
  const AppImMessagePage({
    required this.messages,
    required this.nextAfterSeq,
    required this.nextBeforeSeq,
    required this.hasMoreBefore,
  });

  factory AppImMessagePage.fromJson(Object? value, int organization) {
    final map = imMap(value, 'message page');
    final rawMessages = map['messages'];
    if (rawMessages is! List) {
      throw const FormatException('message page.messages 无效');
    }
    final messages = rawMessages
        .map((item) => AppImMessage.fromHttp(item, organization))
        .toList(growable: false);
    final nextAfter = imInt(map, 'next_after_seq', 'next_after_seq');
    final nextBefore = imInt(map, 'next_before_seq', 'next_before_seq');
    if (nextAfter < 0 || nextBefore < 0) {
      throw const FormatException('消息分页游标无效');
    }
    return AppImMessagePage(
      messages: messages,
      nextAfterSeq: nextAfter,
      nextBeforeSeq: nextBefore,
      hasMoreBefore: imBool(
        map,
        'has_more_before',
        'has_more_before',
        missingAsFalse: true,
      ),
    );
  }

  final List<AppImMessage> messages;
  final int nextAfterSeq;
  final int nextBeforeSeq;
  final bool hasMoreBefore;
}

Map<String, Object?> imMap(Object? value, String field) {
  if (value is! Map) throw FormatException('$field 格式无效');
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String imString(
  Map<String, Object?> map,
  String key,
  String field, {
  bool allowEmpty = false,
  bool missingAsEmpty = false,
}) {
  final value = map[key];
  if (value == null && missingAsEmpty) return '';
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('$field 格式无效');
  }
  return value.trim();
}

int imInt(Map<String, Object?> map, String key, String field) {
  final value = map[key];
  if (value is! int) throw FormatException('$field 格式无效');
  return value;
}

bool imBool(
  Map<String, Object?> map,
  String key,
  String field, {
  bool missingAsFalse = false,
}) {
  final value = map[key];
  if (value == null && missingAsFalse) return false;
  if (value is! bool) throw FormatException('$field 格式无效');
  return value;
}

Map<String, Object?>? _content(Object? value, String status, String field) {
  if (status != 'normal') return null;
  return imMap(value, '$field.content');
}

void _validateMessageContent(
  int messageType,
  String status,
  Map<String, Object?>? content,
) {
  if (status != 'normal') return;
  if (messageType == 1) {
    final text = content?['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const FormatException('文本消息内容无效');
    }
    return;
  }
  if (!const {2, 3, 4, 11}.contains(messageType)) return;
  final fileId = content?['file_id'];
  final name = content?['name'];
  final size = content?['size'];
  final mimeType = content?['mime_type'];
  final extension = content?['extension'];
  if (fileId is! String ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(fileId) ||
      name is! String ||
      name.trim().isEmpty ||
      size is! int ||
      size <= 0 ||
      mimeType is! String ||
      extension is! String ||
      extension.trim().isEmpty) {
    throw const FormatException('附件消息内容无效');
  }
}

int _imOptionalInt(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}
