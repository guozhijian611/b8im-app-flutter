import 'dart:convert';

import '../discovery/tenant_config.dart';
import '../network/app_api_client.dart';
import '../im/group_member_access.dart';
import '../session/app_session.dart';

final class AnnouncementItem {
  const AnnouncementItem({
    required this.id,
    required this.title,
    required this.summary,
    required this.publishedAt,
    required this.isRead,
    required this.displayMode,
  });

  final int id;
  final String title;
  final String summary;
  final String publishedAt;
  final bool isRead;
  final String displayMode;
}

final class AnnouncementDetail {
  const AnnouncementDetail({
    required this.item,
    required this.content,
    required this.readAckRequired,
  });

  final AnnouncementItem item;
  final String content;
  final bool readAckRequired;
}

final class CustomerServiceConversation {
  const CustomerServiceConversation({
    required this.id,
    required this.subject,
    required this.status,
    required this.createdAt,
  });

  final int id;
  final String subject;
  final String status;
  final String createdAt;
}

final class FavoriteItem {
  const FavoriteItem({
    required this.id,
    required this.targetType,
    required this.title,
    required this.summary,
    required this.createdAt,
  });

  final int id;
  final String targetType;
  final String title;
  final String summary;
  final String createdAt;
}

final class I18nLocaleItem {
  const I18nLocaleItem({
    required this.code,
    required this.name,
    required this.isDefault,
  });

  final String code;
  final String name;
  final bool isDefault;
}

final class I18nMessages {
  const I18nMessages({required this.locale, required this.messages});

  final String locale;
  final Map<String, String> messages;
}

final class MomentItem {
  const MomentItem({
    required this.id,
    required this.userId,
    required this.content,
    required this.visibility,
    required this.likeCount,
    required this.commentCount,
    required this.liked,
    required this.createdAt,
  });

  final int id;
  final String userId;
  final String content;
  final String visibility;
  final int likeCount;
  final int commentCount;
  final bool liked;
  final String createdAt;

  MomentItem copyWith({bool? liked, int? likeCount}) => MomentItem(
    id: id,
    userId: userId,
    content: content,
    visibility: visibility,
    likeCount: likeCount ?? this.likeCount,
    commentCount: commentCount,
    liked: liked ?? this.liked,
    createdAt: createdAt,
  );
}

final class RobotSingleItem {
  const RobotSingleItem({
    required this.id,
    required this.name,
    required this.description,
    required this.welcomeText,
  });

  final int id;
  final String name;
  final String description;
  final String welcomeText;
}

final class RobotReply {
  const RobotReply({required this.matched, required this.text});

  final bool matched;
  final String text;
}

final class SearchMessageHit {
  const SearchMessageHit({
    required this.messageId,
    required this.conversationId,
    required this.conversationType,
    required this.senderOrganization,
    required this.senderUserId,
    required this.messageType,
    required this.messageSeq,
    required this.content,
    required this.sentAt,
  });

  final String messageId;
  final String conversationId;
  final int conversationType;
  final int senderOrganization;
  final String senderUserId;
  final int messageType;
  final String messageSeq;
  final String content;
  final String? sentAt;

  String get senderIdentityLabel => '机构 $senderOrganization · $senderUserId';
}

final class SearchMessageSenderFilter {
  SearchMessageSenderFilter({
    required int senderOrganization,
    required String senderUserId,
  }) : senderOrganization = _positiveJsonInt(
         senderOrganization,
         '搜索筛选.sender_organization',
       ),
       senderUserId = _canonicalAccessId(senderUserId, '搜索筛选.sender_user_id');

  final int senderOrganization;
  final String senderUserId;
}

final class StickerPackItem {
  const StickerPackItem({
    required this.id,
    required this.name,
    required this.description,
  });

  final int id;
  final String name;
  final String description;
}

final class StickerAssetItem {
  const StickerAssetItem({
    required this.id,
    required this.packId,
    required this.name,
    required this.fileId,
  });

  final int id;
  final int packId;
  final String name;
  final String fileId;
}

abstract interface class AppModuleGateway {
  Future<List<AnnouncementItem>> fetchAnnouncements();
  Future<AnnouncementDetail> fetchAnnouncement(int id);
  Future<void> acknowledgeAnnouncement(int id);

  Future<List<CustomerServiceConversation>> fetchCustomerConversations();
  Future<CustomerServiceConversation> createCustomerConversation(
    String subject,
  );

  Future<List<FavoriteItem>> fetchFavorites();
  Future<FavoriteItem> createFavoriteNote({
    required String title,
    required String summary,
  });
  Future<void> deleteFavorite(int id);

  Future<List<I18nLocaleItem>> fetchLocales();
  Future<I18nMessages> fetchMessages(String locale);

  Future<List<MomentItem>> fetchMoments();
  Future<MomentItem> createMoment(String content);
  Future<MomentItem> toggleMomentLike(MomentItem moment);

  Future<List<RobotSingleItem>> fetchRobots();
  Future<RobotReply> matchRobot(int robotId, String text);

  Future<List<SearchMessageHit>> searchMessages(
    String keyword, {
    SearchMessageSenderFilter? sender,
  });

  Future<List<StickerPackItem>> fetchStickerPacks();
  Future<List<StickerAssetItem>> fetchStickerItems(int packId);

  void close();
}

final class AppModuleApiService implements AppModuleGateway {
  AppModuleApiService({
    required this.tenant,
    required this.session,
    AppApiClient? apiClient,
  }) : _api = apiClient ?? AppApiClient(),
       _ownsApi = apiClient == null;

  final TenantConfig tenant;
  final AppSession session;
  final AppApiClient _api;
  final bool _ownsApi;

  @override
  Future<List<AnnouncementItem>> fetchAnnouncements() async {
    final data = _map(
      await _get('/saimulti/app/announcement/index', {
        'page': '1',
        'limit': '50',
      }),
      '公告列表',
    );
    final rows = _list(data['list'], '公告列表.list');
    _nonNegativeInt(data['total'], '公告列表.total');
    return rows
        .map((row) => _announcement(_map(row, '公告列表项目')))
        .toList(growable: false);
  }

  @override
  Future<AnnouncementDetail> fetchAnnouncement(int id) async {
    final data = _map(
      await _get('/saimulti/app/announcement/read', {'id': '$id'}),
      '公告详情',
    );
    final item = _announcement(data);
    if (item.id != id) throw const FormatException('公告详情 id 不一致');
    return AnnouncementDetail(
      item: item,
      content: _string(data['content'], '公告详情.content'),
      readAckRequired: _boolean(
        data['read_ack_required'],
        '公告详情.read_ack_required',
      ),
    );
  }

  @override
  Future<void> acknowledgeAnnouncement(int id) async {
    final data = _map(
      await _post('/saimulti/app/announcement/acknowledge', {'id': id}),
      '公告确认',
    );
    if (_positiveInt(data['announcement_id'], '公告确认.announcement_id') != id) {
      throw const FormatException('公告确认 id 不一致');
    }
    _boolean(data['recorded'], '公告确认.recorded');
  }

  @override
  Future<List<CustomerServiceConversation>> fetchCustomerConversations() async {
    final rows = _pageRows(
      await _get('/saimulti/app/customer-service/conversation/index', {
        'page': '1',
        'limit': '50',
      }),
      '客服会话',
    );
    return rows
        .map((row) => _customerConversation(_map(row, '客服会话项目')))
        .toList(growable: false);
  }

  @override
  Future<CustomerServiceConversation> createCustomerConversation(
    String subject,
  ) async {
    return _customerConversation(
      _map(
        await _post('/saimulti/app/customer-service/conversation/save', {
          'subject': subject.trim(),
        }),
        '创建客服会话',
      ),
    );
  }

  @override
  Future<List<FavoriteItem>> fetchFavorites() async {
    final rows = _pageRows(
      await _get('/saimulti/app/favorite/index', {'page': '1', 'limit': '50'}),
      '收藏列表',
    );
    return rows
        .map((row) => _favorite(_map(row, '收藏项目')))
        .toList(growable: false);
  }

  @override
  Future<FavoriteItem> createFavoriteNote({
    required String title,
    required String summary,
  }) async {
    return _favorite(
      _map(
        await _post('/saimulti/app/favorite/save', {
          'target_type': 'text',
          'title': title.trim(),
          'summary': summary.trim(),
          'payload': <String, Object?>{'text': summary.trim()},
        }),
        '创建收藏',
      ),
    );
  }

  @override
  Future<void> deleteFavorite(int id) async {
    final data = _map(
      await _post('/saimulti/app/favorite/destroy', {
        'ids': [id],
      }),
      '删除收藏',
    );
    if (_nonNegativeInt(data['deleted'], '删除收藏.deleted') != 1) {
      throw const FormatException('收藏未删除');
    }
  }

  @override
  Future<List<I18nLocaleItem>> fetchLocales() async {
    final data = _map(await _get('/saimulti/app/i18n/locales'), '语言列表');
    return _list(data['items'], '语言列表.items')
        .map((row) {
          final item = _map(row, '语言项目');
          final rawDefault = item['is_default'];
          final isDefault = rawDefault is bool
              ? rawDefault
              : _nonNegativeInt(rawDefault, '语言项目.is_default') == 1;
          return I18nLocaleItem(
            code: _string(item['code'], '语言项目.code'),
            name: _string(item['name'], '语言项目.name'),
            isDefault: isDefault,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<I18nMessages> fetchMessages(String locale) async {
    final data = _map(
      await _get('/saimulti/app/i18n/messages', {'locale': locale}),
      '词条包',
    );
    final resolvedLocale = _string(data['locale'], '词条包.locale');
    if (resolvedLocale != locale) throw const FormatException('词条包 locale 不一致');
    final rawMessages = _map(data['messages'], '词条包.messages');
    final messages = <String, String>{};
    for (final entry in rawMessages.entries) {
      if (entry.key.trim().isEmpty || entry.value is! String) {
        throw const FormatException('词条包 messages 格式无效');
      }
      messages[entry.key] = entry.value! as String;
    }
    return I18nMessages(
      locale: resolvedLocale,
      messages: Map.unmodifiable(messages),
    );
  }

  @override
  Future<List<MomentItem>> fetchMoments() async {
    final rows = _pageRows(
      await _get('/saimulti/app/moments/feed', {'page': '1', 'limit': '50'}),
      '朋友圈动态',
    );
    return rows
        .map((row) => _moment(_map(row, '朋友圈动态项目')))
        .toList(growable: false);
  }

  @override
  Future<MomentItem> createMoment(String content) async {
    return _moment(
      _map(
        await _post('/saimulti/app/moments/save', {
          'content': content.trim(),
          'visibility': 'friends',
          'media': <Object?>[],
        }),
        '发布动态',
      ),
    );
  }

  @override
  Future<MomentItem> toggleMomentLike(MomentItem moment) async {
    final data = _map(
      await _post('/saimulti/app/moments/likeToggle', {'post_id': moment.id}),
      '动态点赞',
    );
    return moment.copyWith(
      liked: _boolean(data['liked'], '动态点赞.liked'),
      likeCount: _nonNegativeInt(data['like_count'], '动态点赞.like_count'),
    );
  }

  @override
  Future<List<RobotSingleItem>> fetchRobots() async {
    final rows = _pageRows(
      await _get('/saimulti/app/robot-single/index', {
        'page': '1',
        'limit': '50',
      }),
      '机器人列表',
    );
    return rows
        .map((row) {
          final item = _map(row, '机器人项目');
          return RobotSingleItem(
            id: _positiveInt(item['id'], '机器人项目.id'),
            name: _string(item['name'], '机器人项目.name'),
            description: _optionalString(
              item['description'],
              '机器人项目.description',
            ),
            welcomeText: _optionalString(
              item['welcome_text'],
              '机器人项目.welcome_text',
            ),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<RobotReply> matchRobot(int robotId, String text) async {
    final data = _map(
      await _post('/saimulti/app/robot-single/match', {
        'robot_id': robotId,
        'text': text.trim(),
      }),
      '机器人回复',
    );
    return RobotReply(
      matched: _boolean(data['matched'], '机器人回复.matched'),
      text: _string(data['reply_text'], '机器人回复.reply_text'),
    );
  }

  @override
  Future<List<SearchMessageHit>> searchMessages(
    String keyword, {
    SearchMessageSenderFilter? sender,
  }) async {
    final groupAccess = GroupMemberAccessRegistry.lookup(
      session.organization,
      session.user.userId,
    );
    if (groupAccess == null) {
      throw StateError('群成员访问快照尚未初始化');
    }
    final groupEpoch = groupAccess.captureEpoch();
    final query = <String, String>{
      'q': keyword.trim(),
      'page': '1',
      'limit': '50',
      if (sender != null) ...{
        'sender_organization': '${sender.senderOrganization}',
        'sender_user_id': sender.senderUserId,
      },
    };
    final rows = _pageRows(
      await _get('/saimulti/app/search/messages', query),
      '消息搜索',
    );
    final hits = rows
        .map((row) {
          final item = _map(row, '搜索结果');
          final conversationType = _positiveJsonInt(
            item['conversation_type'],
            '搜索结果.conversation_type',
          );
          if (conversationType != 1 && conversationType != 2) {
            throw const FormatException('搜索结果.conversation_type 只允许 1 或 2');
          }
          return SearchMessageHit(
            messageId: _canonicalAccessId(
              item['message_id'],
              '搜索结果.message_id',
            ),
            conversationId: _canonicalAccessId(
              item['conversation_id'],
              '搜索结果.conversation_id',
            ),
            conversationType: conversationType,
            senderOrganization: _positiveJsonInt(
              item['sender_organization'],
              '搜索结果.sender_organization',
            ),
            senderUserId: _canonicalAccessId(
              item['sender_user_id'],
              '搜索结果.sender_user_id',
            ),
            messageType: _positiveJsonInt(
              item['message_type'],
              '搜索结果.message_type',
            ),
            messageSeq: _positiveDecimalString(
              item['message_seq'],
              '搜索结果.message_seq',
            ),
            content: _jsonString(item['content'], '搜索结果.content'),
            sentAt: _requiredNullableNonemptyString(
              item,
              'sent_at',
              '搜索结果.sent_at',
            ),
          );
        })
        .toList(growable: false);
    groupEpoch.assertCurrent();
    for (final hit in hits) {
      final entry = groupAccess.entry(hit.conversationId);
      if (hit.conversationType == 2 &&
          (entry == null ||
              !entry.containsMessageSequenceDecimal(hit.messageSeq))) {
        throw const FormatException('搜索结果包含未授权或周期外群消息');
      }
      if (hit.conversationType == 1 && entry != null) {
        throw const FormatException('搜索结果 conversation_type 与群访问映射冲突');
      }
    }
    groupEpoch.assertCurrent();
    return hits;
  }

  @override
  Future<List<StickerPackItem>> fetchStickerPacks() async {
    final data = _map(await _get('/saimulti/app/sticker/packs'), '表情包列表');
    return _list(data['items'], '表情包列表.items')
        .map((row) {
          final item = _map(row, '表情包项目');
          return StickerPackItem(
            id: _positiveInt(item['id'], '表情包项目.id'),
            name: _string(item['name'], '表情包项目.name'),
            description: _optionalString(
              item['description'],
              '表情包项目.description',
            ),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<StickerAssetItem>> fetchStickerItems(int packId) async {
    final data = _map(
      await _get('/saimulti/app/sticker/items', {'pack_id': '$packId'}),
      '表情项目列表',
    );
    return _list(data['items'], '表情项目列表.items')
        .map((row) {
          final item = _map(row, '表情项目');
          final resolvedPackId = _positiveInt(item['pack_id'], '表情项目.pack_id');
          if (resolvedPackId != packId) {
            throw const FormatException('表情项目 pack_id 不一致');
          }
          return StickerAssetItem(
            id: _positiveInt(item['id'], '表情项目.id'),
            packId: resolvedPackId,
            name: _optionalString(item['name'], '表情项目.name'),
            fileId: _string(item['file_id'], '表情项目.file_id'),
          );
        })
        .toList(growable: false);
  }

  Future<Object?> _get(String path, [Map<String, String>? query]) => _api
      .request(tenant, path, accessToken: session.accessToken, query: query);

  Future<Object?> _post(String path, Map<String, Object?> body) => _api.request(
    tenant,
    path,
    method: AppApiMethod.post,
    accessToken: session.accessToken,
    body: body,
  );

  @override
  void close() {
    if (_ownsApi) _api.close();
  }
}

AnnouncementItem _announcement(Map<String, Object?> item) {
  final displayMode = _string(item['display_mode'], '公告.display_mode');
  if (!const {'list', 'popup', 'both'}.contains(displayMode)) {
    throw const FormatException('公告 display_mode 无效');
  }
  return AnnouncementItem(
    id: _positiveInt(item['id'], '公告.id'),
    title: _string(item['title'], '公告.title'),
    summary: _optionalString(item['summary'], '公告.summary'),
    publishedAt: _string(item['published_at'], '公告.published_at'),
    isRead: _boolean(item['is_read'], '公告.is_read'),
    displayMode: displayMode,
  );
}

CustomerServiceConversation _customerConversation(Map<String, Object?> item) {
  final status = _string(item['status'], '客服会话.status');
  if (!const {'queued', 'assigned', 'active', 'closed'}.contains(status)) {
    throw const FormatException('客服会话 status 无效');
  }
  return CustomerServiceConversation(
    id: _positiveInt(item['id'], '客服会话.id'),
    subject: _string(item['subject'], '客服会话.subject'),
    status: status,
    createdAt: _string(item['create_time'], '客服会话.create_time'),
  );
}

FavoriteItem _favorite(Map<String, Object?> item) {
  final targetType = _string(item['target_type'], '收藏.target_type');
  if (!const {'message', 'file', 'link', 'text'}.contains(targetType)) {
    throw const FormatException('收藏 target_type 无效');
  }
  return FavoriteItem(
    id: _positiveInt(item['id'], '收藏.id'),
    targetType: targetType,
    title: _string(item['title'], '收藏.title'),
    summary: _optionalString(item['summary'], '收藏.summary'),
    createdAt: _string(item['create_time'], '收藏.create_time'),
  );
}

MomentItem _moment(Map<String, Object?> item) => MomentItem(
  id: _positiveInt(item['id'], '动态.id'),
  userId: _string(item['user_id'], '动态.user_id'),
  content: _string(item['content'], '动态.content'),
  visibility: _string(item['visibility'], '动态.visibility'),
  likeCount: _nonNegativeInt(item['like_count'], '动态.like_count'),
  commentCount: _nonNegativeInt(item['comment_count'], '动态.comment_count'),
  liked: _boolean(item['liked'], '动态.liked'),
  createdAt: _string(item['create_time'], '动态.create_time'),
);

List<Object?> _pageRows(Object? value, String field) {
  final page = _map(value, field);
  _positiveInt(page['current_page'], '$field.current_page');
  _positiveInt(page['per_page'], '$field.per_page');
  _nonNegativeInt(page['total'], '$field.total');
  return _list(page['data'], '$field.data');
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map) throw FormatException('$field 格式无效');
  return value.map((key, item) => MapEntry(key.toString(), item));
}

List<Object?> _list(Object? value, String field) {
  if (value is! List) throw FormatException('$field 格式无效');
  return value.cast<Object?>();
}

String _string(Object? value, String field) {
  if ((value is! String && value is! num) || value.toString().trim().isEmpty) {
    throw FormatException('$field 格式无效');
  }
  return value.toString().trim();
}

String _optionalString(Object? value, String field) {
  if (value == null) return '';
  if (value is! String && value is! num) throw FormatException('$field 格式无效');
  return value.toString().trim();
}

String _jsonString(Object? value, String field) {
  if (value is! String) throw FormatException('$field 格式无效');
  return value;
}

String? _requiredNullableNonemptyString(
  Map<String, Object?> value,
  String key,
  String field,
) {
  if (!value.containsKey(key)) throw FormatException('$field 格式无效');
  final item = value[key];
  if (item == null) return null;
  if (item is! String || item.trim().isEmpty) {
    throw FormatException('$field 格式无效');
  }
  return item;
}

int _positiveInt(Object? value, String field) {
  final integer = _integer(value, field);
  if (integer <= 0) throw FormatException('$field 格式无效');
  return integer;
}

int _positiveJsonInt(Object? value, String field) {
  if (value is! int || value <= 0 || value > 9007199254740991) {
    throw FormatException('$field 格式无效');
  }
  return value;
}

const _invalidAccessIdFragments = <String>[
  '\u0000',
  '\u0009',
  '\u000A',
  '\u000B',
  '\u000D',
  '|',
];

String _canonicalAccessId(Object? value, String field) {
  if (value is! String ||
      value.isEmpty ||
      utf8.decode(utf8.encode(value)) != value ||
      utf8.encode(value).length > 64 ||
      value.startsWith(' ') ||
      value.endsWith(' ') ||
      _invalidAccessIdFragments.any(value.contains)) {
    throw FormatException('$field 格式无效');
  }
  return value;
}

int _nonNegativeInt(Object? value, String field) {
  final integer = _integer(value, field);
  if (integer < 0) throw FormatException('$field 格式无效');
  return integer;
}

String _positiveDecimalString(Object? value, String field) {
  final normalized = normalizeGroupAccessPositiveDecimal(value);
  if (normalized.isEmpty) throw FormatException('$field 格式无效');
  return normalized;
}

int _integer(Object? value, String field) {
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  if (value is String && RegExp(r'^-?\d+$').hasMatch(value)) {
    return int.parse(value);
  }
  throw FormatException('$field 格式无效');
}

bool _boolean(Object? value, String field) {
  if (value is! bool) throw FormatException('$field 格式无效');
  return value;
}
