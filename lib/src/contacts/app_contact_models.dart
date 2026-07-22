import '../messaging/contact_display_label.dart';

final class AppContact {
  const AppContact({
    required this.id,
    required this.organization,
    required this.organizationName,
    required this.companyName,
    required this.isCrossOrganization,
    required this.userId,
    required this.account,
    required this.nickname,
    required this.signature,
    required this.avatarUrl,
    required this.mobile,
    required this.imShortNo,
    required this.statusText,
    required this.remark,
    required this.relationStatus,
    required this.isSystem,
  });

  factory AppContact.fromJson(Object? value, {String field = 'contact'}) {
    final map = contactMap(value, field);
    final userId = contactString(map['user_id']);
    final organization = contactInt(map['organization']);
    if (userId.isEmpty || organization <= 0) {
      throw FormatException('$field 复合身份格式无效');
    }
    return AppContact(
      id: contactString(map['id']),
      organization: organization,
      organizationName: contactString(map['organization_name']),
      companyName: contactString(
        map['company_name'],
        fallback: contactString(map['organization_name']),
      ),
      isCrossOrganization: contactBool(map['is_cross_organization']),
      userId: userId,
      account: contactString(map['account']),
      nickname: contactString(map['nickname']),
      signature: contactString(map['signature']),
      avatarUrl: contactString(map['avatar_url']),
      mobile: contactString(map['mobile']),
      imShortNo: contactString(map['im_short_no']),
      statusText: contactString(map['status_text'], fallback: '正常'),
      remark: contactString(map['remark']),
      relationStatus: contactString(map['relation_status'], fallback: 'none'),
      isSystem: contactBool(map['is_system']),
    );
  }

  final String id;
  final int organization;
  final String organizationName;
  final String companyName;
  final bool isCrossOrganization;
  final String userId;
  final String account;
  final String nickname;
  final String signature;
  final String avatarUrl;
  final String mobile;
  final String imShortNo;
  final String statusText;
  final String remark;
  final String relationStatus;
  final bool isSystem;

  String get displayName => ContactDisplayLabel.format(
    nickname: remark.isNotEmpty ? remark : nickname,
    account: account,
    companyName: companyName,
    isCrossOrganization: isCrossOrganization,
  );

  String get subtitle => signature.isNotEmpty
      ? signature
      : account.isNotEmpty
      ? account
      : imShortNo.isNotEmpty
      ? imShortNo
      : '企业联系人';
}

final class AppFriendRequest {
  const AppFriendRequest({
    required this.id,
    required this.direction,
    required this.message,
    required this.status,
    required this.statusText,
    required this.createTime,
    required this.fromOrganization,
    required this.toOrganization,
    required this.fromUser,
    required this.toUser,
  });

  factory AppFriendRequest.fromJson(Object? value) {
    final map = contactMap(value, 'friend_request');
    final id = contactInt(map['id']);
    final status = contactInt(map['status']);
    final direction = contactString(map['direction']);
    final fromOrganization = contactInt(map['from_organization']);
    final toOrganization = contactInt(map['to_organization']);
    final fromUser = map['from_user'] == null
        ? null
        : AppContact.fromJson(map['from_user'], field: 'from_user');
    final toUser = map['to_user'] == null
        ? null
        : AppContact.fromJson(map['to_user'], field: 'to_user');
    if (id <= 0 ||
        status < 0 ||
        fromOrganization <= 0 ||
        toOrganization <= 0 ||
        (fromUser != null && fromUser.organization != fromOrganization) ||
        (toUser != null && toUser.organization != toOrganization) ||
        !{'incoming', 'outgoing'}.contains(direction)) {
      throw const FormatException('好友申请格式无效');
    }
    return AppFriendRequest(
      id: id,
      direction: direction,
      message: contactString(map['message']),
      status: status,
      statusText: contactString(map['status_text']),
      createTime: contactString(map['create_time']),
      fromOrganization: fromOrganization,
      toOrganization: toOrganization,
      fromUser: fromUser,
      toUser: toUser,
    );
  }

  final int id;
  final String direction;
  final String message;
  final int status;
  final String statusText;
  final String createTime;
  final int fromOrganization;
  final int toOrganization;
  final AppContact? fromUser;
  final AppContact? toUser;

  AppContact? get displayUser => direction == 'incoming' ? fromUser : toUser;
  int get peerOrganization =>
      direction == 'incoming' ? fromOrganization : toOrganization;
  bool hasAuthoritativeContext(int currentOrganization) {
    final user = displayUser;
    if (user == null || user.organization != peerOrganization) return false;
    return direction == 'incoming'
        ? toOrganization == currentOrganization
        : fromOrganization == currentOrganization;
  }

  bool get isPendingIncoming => direction == 'incoming' && status == 1;
}

Map<String, Object?> contactMap(Object? value, String field) {
  if (value is! Map) throw FormatException('$field 格式无效');
  return value.map((key, item) => MapEntry(key.toString(), item));
}

String contactString(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value is! String && value is! num) return fallback;
  final result = value.toString().trim();
  return result.isEmpty ? fallback : result;
}

int contactInt(Object? value) {
  if (value is int) return value;
  return int.tryParse(contactString(value)) ?? 0;
}

bool contactBool(Object? value) =>
    value == true || value == 1 || value == '1' || value == 'true';
