import 'package:b8im_app_flutter/src/messaging/contact_display_label.dart';

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

final class AppImReceipt {
  const AppImReceipt({
    required this.messageId,
    required this.conversationId,
    required this.messageSeq,
    required this.senderId,
    required this.userId,
    required this.status,
    required this.time,
  });

  factory AppImReceipt.fromJson(Object? value, String field) {
    final map = imMap(value, field);
    final sequence = imInt(map, 'message_seq', '$field.message_seq');
    if (sequence <= 0) throw FormatException('$field.message_seq 格式无效');
    return AppImReceipt(
      messageId: imString(map, 'message_id', '$field.message_id'),
      conversationId: imString(
        map,
        'conversation_id',
        '$field.conversation_id',
      ),
      messageSeq: sequence,
      senderId: imString(map, 'sender_id', '$field.sender_id'),
      userId: imString(map, 'user_id', '$field.user_id'),
      status: AppImDeliveryStatus.parse(
        imString(map, 'status', '$field.status'),
        '$field.status',
      ),
      time: imString(map, 'time', '$field.time'),
    );
  }

  final String messageId;
  final String conversationId;
  final int messageSeq;
  final String senderId;
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
    required this.userId,
    required this.time,
  });

  factory AppImConversationReadState.fromJson(Object? value, String field) {
    final map = imMap(value, field);
    final sequence = imInt(map, 'last_read_seq', '$field.last_read_seq');
    final unread = imInt(map, 'unread_count', '$field.unread_count');
    if (sequence <= 0 || unread < 0) {
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
      userId: imString(map, 'user_id', '$field.user_id'),
      time: imString(map, 'time', '$field.time'),
    );
  }

  final String conversationId;
  final String lastReadMessageId;
  final int lastReadSeq;
  final int unreadCount;
  final String userId;
  final String time;
}

final class AppImUserSummary {
  const AppImUserSummary({
    required this.userId,
    required this.account,
    required this.nickname,
    required this.avatarUrl,
    this.organization = 0,
    this.companyName = '',
    this.isCrossOrganization = false,
    this.displayNameOverride = '',
  });

  factory AppImUserSummary.fromJson(Object? value, String field) {
    final map = imMap(value, field);
    final nickname = imString(map, 'nickname', '$field.nickname', allowEmpty: true);
    final account = imString(map, 'account', '$field.account', allowEmpty: true);
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
    final resolvedCompany =
        companyName.isNotEmpty ? companyName : organizationName;
    final isCross = map['is_cross_organization'] == true ||
        map['is_cross_organization'] == 1 ||
        map['is_cross_organization'] == '1';
    final serverDisplay = imString(
      map,
      'display_name',
      '$field.display_name',
      allowEmpty: true,
    );
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
      organization: _imOptionalInt(map, 'organization'),
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

  factory AppImMessage.fromHttp(Object? value, int organization) {
    final map = imMap(value, 'HTTP message');
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

  AppImMessage copyWith({AppImDeliveryStatus? deliveryStatus}) {
    return AppImMessage(
      organization: organization,
      globalSeq: globalSeq,
      conversationId: conversationId,
      conversationType: conversationType,
      messageId: messageId,
      messageSeq: messageSeq,
      clientMsgId: clientMsgId,
      senderId: senderId,
      senderUser: senderUser,
      messageType: messageType,
      content: content,
      status: status,
      editTime: editTime,
      editCount: editCount,
      createTime: createTime,
      updateTime: updateTime,
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
