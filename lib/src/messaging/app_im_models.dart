final class AppImUserSummary {
  const AppImUserSummary({
    required this.userId,
    required this.account,
    required this.nickname,
    required this.avatarUrl,
  });

  factory AppImUserSummary.fromJson(Object? value, String field) {
    final map = imMap(value, field);
    return AppImUserSummary(
      userId: imString(map, 'user_id', '$field.user_id'),
      account: imString(map, 'account', '$field.account', allowEmpty: true),
      nickname: imString(map, 'nickname', '$field.nickname', allowEmpty: true),
      avatarUrl: imString(
        map,
        'avatar_url',
        '$field.avatar_url',
        allowEmpty: true,
      ),
    );
  }

  final String userId;
  final String account;
  final String nickname;
  final String avatarUrl;

  String get displayName => nickname.isNotEmpty ? nickname : account;
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
  });

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
    required this.senderId,
    required this.senderUser,
    required this.messageType,
    required this.content,
    required this.status,
    required this.editTime,
    required this.editCount,
    required this.createTime,
    required this.updateTime,
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
    );
  }

  factory AppImMessage.fromHttp(Object? value, int organization) {
    final map = imMap(value, 'HTTP message');
    final rawStatus = imInt(map, 'status', 'message.status');
    final status = switch (rawStatus) {
      1 => 'normal',
      2 => 'recalled',
      3 => 'deleted_both',
      _ => throw const FormatException('HTTP 消息 status 无效'),
    };
    return _fromMap(
      map,
      organization: organization,
      globalSeq: null,
      status: status,
      content: _content(map['content'], status, 'HTTP message'),
    );
  }

  static AppImMessage _fromMap(
    Map<String, Object?> map, {
    required int organization,
    required String? globalSeq,
    required String status,
    required Map<String, Object?>? content,
  }) {
    final type = imInt(map, 'conversation_type', 'message.conversation_type');
    final sequence = imInt(map, 'message_seq', 'message.message_seq');
    final messageType = imInt(map, 'message_type', 'message.message_type');
    if ((type != 1 && type != 2) || sequence <= 0 || messageType <= 0) {
      throw const FormatException('消息类型或序号无效');
    }
    final rawSender = map['sender_user'];
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
      senderId: imString(map, 'sender_id', 'message.sender_id'),
      senderUser: rawSender == null
          ? null
          : AppImUserSummary.fromJson(rawSender, 'message.sender_user'),
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
    );
  }

  final int organization;
  final String? globalSeq;
  final String conversationId;
  final int conversationType;
  final String messageId;
  final int messageSeq;
  final String clientMsgId;
  final String senderId;
  final AppImUserSummary? senderUser;
  final int messageType;
  final Map<String, Object?>? content;
  final String status;
  final String editTime;
  final int editCount;
  final String createTime;
  final String updateTime;

  String get displayText {
    if (status == 'recalled') return '消息已撤回';
    if (status == 'deleted_both') return '消息已删除';
    if (messageType != 1) return '[暂不支持的消息类型]';
    final text = content?['text'];
    return text is String && text.isNotEmpty ? text : '[空文本]';
  }
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
