import 'package:b8im_app_flutter/src/messaging/app_im_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const single = AppImConversationIdentityContext(
    organization: 1,
    userId: 'current',
    conversationId: 'single-01',
    conversationType: 1,
    peerOrganization: 2,
    peerUserId: 'peer',
  );
  const group = AppImConversationIdentityContext(
    organization: 1,
    userId: 'current',
    conversationId: 'group-01',
    conversationType: 2,
    peerOrganization: null,
    peerUserId: null,
  );

  test('单聊消息只接受当前或 peer 复合身份发送者', () {
    expect(single.acceptsMessage(_message()), isTrue);
    expect(
      single.acceptsMessage(
        _message(senderOrganization: 3, senderId: 'third-party'),
      ),
      isFalse,
    );
    expect(
      single.acceptsMessage(_message(senderOrganization: 1, senderId: 'peer')),
      isFalse,
    );
  });

  test('群消息与 receipt/read 拒绝非 home organization', () {
    expect(
      group.acceptsMessage(
        _message(
          conversationId: 'group-01',
          conversationType: 2,
          senderOrganization: 2,
          senderId: 'foreign-member',
        ),
      ),
      isFalse,
    );
    expect(
      group.classifyReceipt(
        const AppImReceipt(
          messageId: 'message-01',
          conversationId: 'group-01',
          messageSeq: 1,
          senderOrganization: 1,
          senderId: 'current',
          userOrganization: 2,
          userId: 'foreign-member',
          status: AppImDeliveryStatus.read,
          time: '2026-07-20 12:00:00',
        ),
      ),
      AppImEventDirection.invalid,
    );
    expect(
      group.classifyConversationRead(
        const AppImConversationReadState(
          conversationId: 'group-01',
          lastReadMessageId: 'message-01',
          lastReadSeq: 1,
          unreadCount: 0,
          userOrganization: 2,
          userId: 'foreign-member',
          time: '2026-07-20 12:00:00',
        ),
      ),
      AppImEventDirection.invalid,
    );
  });

  test('单聊 receipt/read 区分 peer 已读我方与我方其他设备已读 peer', () {
    expect(
      single.classifyReceipt(
        const AppImReceipt(
          messageId: 'message-01',
          conversationId: 'single-01',
          messageSeq: 1,
          senderOrganization: 1,
          senderId: 'current',
          userOrganization: 2,
          userId: 'peer',
          status: AppImDeliveryStatus.read,
          time: '2026-07-20 12:00:00',
        ),
      ),
      AppImEventDirection.peerReadsCurrent,
    );
    expect(
      single.classifyReceipt(
        const AppImReceipt(
          messageId: 'message-02',
          conversationId: 'single-01',
          messageSeq: 2,
          senderOrganization: 2,
          senderId: 'peer',
          userOrganization: 1,
          userId: 'current',
          status: AppImDeliveryStatus.read,
          time: '2026-07-20 12:00:00',
        ),
      ),
      AppImEventDirection.currentReadsPeer,
    );
    expect(
      single.classifyConversationRead(
        const AppImConversationReadState(
          conversationId: 'single-01',
          lastReadMessageId: 'message-02',
          lastReadSeq: 2,
          unreadCount: 0,
          userOrganization: 1,
          userId: 'current',
          time: '2026-07-20 12:00:00',
        ),
      ),
      AppImEventDirection.currentReadsPeer,
    );
  });

  test('change_seq 对 stale/duplicate/gap 严格分类', () {
    expect(
      classifyAppImChangeSequence(
        lastConversationSequence: 4,
        lastMessageSequence: 4,
        incomingSequence: 4,
      ),
      AppImChangeSequenceDecision.stale,
    );
    expect(
      classifyAppImChangeSequence(
        lastConversationSequence: 4,
        lastMessageSequence: 2,
        incomingSequence: 6,
      ),
      AppImChangeSequenceDecision.gap,
    );
    expect(
      classifyAppImChangeSequence(
        lastConversationSequence: 4,
        lastMessageSequence: 2,
        incomingSequence: 5,
      ),
      AppImChangeSequenceDecision.apply,
    );
  });

  test('访问快照忽略重复和倒序，只接受 canonical decimal', () {
    final tracker = AppImAccessSnapshotTracker('9');
    expect(tracker.observe('9'), AppImAccessSnapshotObservation.duplicate);
    expect(tracker.observe('8'), AppImAccessSnapshotObservation.stale);
    expect(tracker.observe('10'), AppImAccessSnapshotObservation.fresh);
    expect(tracker.observe('010'), AppImAccessSnapshotObservation.invalid);
  });

  test('访问快照 100→0 保留高水位，仅严格更大的正值可恢复', () {
    final tracker = AppImAccessSnapshotTracker('100');
    expect(tracker.reset('0'), AppImAccessSnapshotObservation.fresh);
    expect(tracker.isCrossOrganizationFailClosed, isTrue);
    expect(tracker.highestPositiveSnapshotId, '100');
    expect(tracker.observe('99'), AppImAccessSnapshotObservation.stale);
    expect(tracker.observe('100'), AppImAccessSnapshotObservation.stale);
    expect(tracker.observe('101'), AppImAccessSnapshotObservation.fresh);
    expect(tracker.isCrossOrganizationFailClosed, isFalse);
  });

  test('访问事件只按 event_id 去重，同 snapshot 多会话均处理', () {
    const first = AppImConversationAccessChanged(
      eventId:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      snapshotId: '100',
      conversationId: 'single-01',
      allowed: false,
      targetOrganization: 1,
      targetUserId: 'current',
      peerOrganization: 2,
      peerUserId: 'peer-01',
    );
    const second = AppImConversationAccessChanged(
      eventId:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      snapshotId: '100',
      conversationId: 'single-02',
      allowed: false,
      targetOrganization: 1,
      targetUserId: 'current',
      peerOrganization: 3,
      peerUserId: 'peer-02',
    );
    final gate = AppImAccessEventGate('100');
    expect(gate.observe(first), AppImAccessEventDecision.apply);
    expect(gate.observe(second), AppImAccessEventDecision.apply);
    expect(gate.observe(first), AppImAccessEventDecision.duplicateEvent);
  });

  test('receipt 协议拒绝 sent，仅接受 delivered/read', () {
    expect(
      () => AppImReceipt.fromJson({
        'message_id': 'message-01',
        'conversation_id': 'single-01',
        'message_seq': 1,
        'sender_organization': 2,
        'sender_id': 'peer',
        'user_organization': 1,
        'user_id': 'current',
        'status': 'sent',
        'time': '2026-07-20 12:00:00',
      }, 'receipt'),
      throwsFormatException,
    );
  });

  test('access_changed 拒绝错误 target、同机构 peer 与非布尔 allowed', () {
    Map<String, Object?> packet({
      Object? allowed = false,
      int targetOrganization = 1,
      int peerOrganization = 2,
    }) => {
      'event_id':
          'abababababababababababababababababababababababababababababababab',
      'event_type': 'conversation.access_changed',
      'conversation_id': 'single-cross-01',
      'conversation_type': 1,
      'cross_org_access_snapshot_id': '2',
      'allowed': allowed,
      'target_organization': targetOrganization,
      'target_user_id': 'current',
      'peer_organization': peerOrganization,
      'peer_user_id': 'peer',
    };

    expect(
      () => AppImConversationAccessChanged.fromJson(
        packet(targetOrganization: 3),
        expectedOrganization: 1,
        expectedUserId: 'current',
      ),
      throwsFormatException,
    );
    expect(
      () => AppImConversationAccessChanged.fromJson(
        packet(peerOrganization: 1),
        expectedOrganization: 1,
        expectedUserId: 'current',
      ),
      throwsFormatException,
    );
    expect(
      () => AppImConversationAccessChanged.fromJson(
        packet(allowed: 0),
        expectedOrganization: 1,
        expectedUserId: 'current',
      ),
      throwsFormatException,
    );
  });

  test('conversation SYNC change 强制 actor 复合身份并拒绝伪造 target', () {
    Map<String, Object?> change() => {
      'conversation_id': 'single-01',
      'change_seq': 1,
      'change_type': 'edit',
      'message_id': 'message-01',
      'message_seq': 1,
      'actor_organization': 2,
      'actor_user_id': 'peer',
      'target_organization': null,
      'target_user_id': null,
      'payload': {
        'content': {'text': 'edited'},
        'edit_time': '2026-07-20 12:00:00',
        'edit_count': 1,
      },
      'create_time': '2026-07-20 12:00:00',
    };

    Map<String, Object?> page(Map<String, Object?> item) => {
      'organization': 1,
      'scope': 'conversation',
      'conversation_id': 'single-01',
      'messages': const [],
      'changes': [item],
      'next_after_seq': 0,
      'next_after_change_seq': 1,
      'messages_has_more': false,
      'changes_has_more': false,
      'cross_org_access_snapshot_id': '1',
    };

    final valid = AppImConversationSyncPage.fromJson(
      page(change()),
      identity: single,
    );
    expect(valid.changes.single.actorOrganization, 2);
    expect(valid.changes.single.actorUserId, 'peer');

    final missingActor = change()..remove('actor_organization');
    final wrongActorOrganization = change()
      ..['actor_organization'] = 1
      ..['actor_user_id'] = 'peer';
    final nonParticipant = change()
      ..['actor_organization'] = 9
      ..['actor_user_id'] = 'intruder';
    final mismatchedTarget = change()
      ..['target_organization'] = 2
      ..['target_user_id'] = 'peer';
    for (final invalid in [
      missingActor,
      wrongActorOrganization,
      nonParticipant,
      mismatchedTarget,
    ]) {
      expect(
        () =>
            AppImConversationSyncPage.fromJson(page(invalid), identity: single),
        throwsFormatException,
      );
    }
  });

  test('conversation SYNC edit 仅允许原消息发送者 actor', () {
    const forged = AppImSyncedMessageChange(
      conversationId: 'single-01',
      changeSeq: 1,
      changeType: 'edit',
      messageId: 'message-01',
      messageSeq: 1,
      actorOrganization: 1,
      actorUserId: 'current',
      targetOrganization: null,
      targetUserId: null,
      payload: {
        'content': {'text': 'forged'},
        'edit_time': '2026-07-20 12:00:00',
        'edit_count': 1,
      },
      createTime: '2026-07-20 12:00:00',
    );
    expect(single.acceptsSyncedChange(forged, _message()), isFalse);
  });
}

AppImMessage _message({
  String conversationId = 'single-01',
  int conversationType = 1,
  int senderOrganization = 2,
  String senderId = 'peer',
}) => AppImMessage(
  organization: 1,
  globalSeq: '1',
  conversationId: conversationId,
  conversationType: conversationType,
  messageId: 'message-01',
  messageSeq: 1,
  clientMsgId: 'client-01',
  senderOrganization: senderOrganization,
  senderId: senderId,
  senderUser: null,
  messageType: 1,
  content: const {'text': 'hello'},
  status: 'normal',
  editTime: '',
  editCount: 0,
  createTime: '2026-07-20 12:00:00',
  updateTime: '2026-07-20 12:00:00',
  deliveryStatus: null,
);
