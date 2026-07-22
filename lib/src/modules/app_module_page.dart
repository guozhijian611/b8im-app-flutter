import 'package:flutter/material.dart';

import 'app_module_api.dart';
import 'client_module_registry.dart';

final class AppModulePage extends StatefulWidget {
  const AppModulePage({
    super.key,
    required this.moduleKey,
    required this.title,
    required this.moduleContext,
  });

  final String moduleKey;
  final String title;
  final ClientModuleContext moduleContext;

  @override
  State<AppModulePage> createState() => _AppModulePageState();
}

final class _AppModulePageState extends State<AppModulePage> {
  late final AppModuleGateway gateway;
  final primary = TextEditingController();
  final secondary = TextEditingController();
  bool loading = true;
  bool saving = false;
  String error = '';
  int selectedId = 0;
  Object? data;
  String resultText = '';

  @override
  void initState() {
    super.initState();
    gateway = AppModuleApiService(
      tenant: widget.moduleContext.tenant,
      session: widget.moduleContext.session,
    );
    load();
  }

  @override
  void dispose() {
    primary.dispose();
    secondary.dispose();
    gateway.close();
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = '';
    });
    try {
      final value = await switch (widget.moduleKey) {
        'announcement' => gateway.fetchAnnouncements(),
        'customer_service' => gateway.fetchCustomerConversations(),
        'favorite' => gateway.fetchFavorites(),
        'i18n' => gateway.fetchLocales(),
        'moments' => gateway.fetchMoments(),
        'robot_single' => gateway.fetchRobots(),
        'search' => Future<List<SearchMessageHit>>.value(const []),
        'sticker' => gateway.fetchStickerPacks(),
        _ => throw UnsupportedError('未注册模块 ${widget.moduleKey}'),
      };
      if (!mounted) return;
      setState(() {
        data = value;
        if (value is List<RobotSingleItem> && value.isNotEmpty) {
          selectedId = value.first.id;
        }
        if (value is List<I18nLocaleItem> && value.isNotEmpty) {
          selectedId = 0;
        }
        if (value is List<StickerPackItem> && value.isNotEmpty) {
          selectedId = value.first.id;
        }
      });
      if (value is List<I18nLocaleItem> && value.isNotEmpty) {
        await selectLocale(value.first.code);
      }
      if (value is List<StickerPackItem> && value.isNotEmpty) {
        await selectStickerPack(value.first.id);
      }
    } catch (value) {
      if (mounted) setState(() => error = value.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> selectLocale(String locale) async {
    try {
      final messages = await gateway.fetchMessages(locale);
      if (mounted) setState(() => data = messages);
    } catch (value) {
      if (mounted) setState(() => error = value.toString());
    }
  }

  Future<void> selectStickerPack(int packId) async {
    try {
      final items = await gateway.fetchStickerItems(packId);
      if (mounted) {
        setState(() {
          selectedId = packId;
          resultText = items
              .map((item) => '${item.name} · ${item.fileId}')
              .join('\n');
        });
      }
    } catch (value) {
      if (mounted) setState(() => error = value.toString());
    }
  }

  Future<void> submit() async {
    final text = primary.text.trim();
    if (text.isEmpty || saving) return;
    setState(() {
      saving = true;
      error = '';
    });
    try {
      switch (widget.moduleKey) {
        case 'customer_service':
          await gateway.createCustomerConversation(text);
        case 'favorite':
          await gateway.createFavoriteNote(
            title: text,
            summary: secondary.text.trim(),
          );
        case 'moments':
          await gateway.createMoment(text);
        case 'robot_single':
          final reply = await gateway.matchRobot(selectedId, text);
          resultText = reply.text;
        case 'search':
          data = await gateway.searchMessages(text);
        default:
          return;
      }
      primary.clear();
      secondary.clear();
      if (widget.moduleKey != 'robot_single' && widget.moduleKey != 'search') {
        await load();
      } else if (mounted) {
        setState(() {});
      }
    } catch (value) {
      if (mounted) setState(() => error = value.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  bool get canCreate => const {
    'customer_service',
    'favorite',
    'moments',
    'robot_single',
    'search',
  }.contains(widget.moduleKey);

  String get hint => switch (widget.moduleKey) {
    'customer_service' => '输入问题主题',
    'favorite' => '输入收藏标题',
    'moments' => '分享新动态',
    'robot_single' => '向机器人提问',
    'search' => '搜索消息内容',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error.isNotEmpty
          ? _ErrorState(message: error, retry: load)
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (canCreate) ...[
                    if (widget.moduleKey == 'robot_single') _robotSelector(),
                    TextField(
                      controller: primary,
                      decoration: InputDecoration(labelText: hint),
                    ),
                    if (widget.moduleKey == 'favorite')
                      TextField(
                        controller: secondary,
                        decoration: const InputDecoration(labelText: '收藏内容'),
                      ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: saving ? null : submit,
                      icon: Icon(
                        widget.moduleKey == 'search' ? Icons.search : Icons.add,
                      ),
                      label: Text(
                        saving
                            ? '处理中…'
                            : widget.moduleKey == 'search'
                            ? '搜索'
                            : '提交',
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (resultText.isNotEmpty)
                    _Card(title: '处理结果', subtitle: resultText),
                  ..._items(),
                ],
              ),
            ),
    );
  }

  Widget _robotSelector() {
    final robots = data is List<RobotSingleItem>
        ? data! as List<RobotSingleItem>
        : const <RobotSingleItem>[];
    return DropdownButtonFormField<int>(
      initialValue: robots.any((item) => item.id == selectedId)
          ? selectedId
          : null,
      decoration: const InputDecoration(labelText: '机器人'),
      items: robots
          .map(
            (item) => DropdownMenuItem(value: item.id, child: Text(item.name)),
          )
          .toList(),
      onChanged: (value) => setState(() => selectedId = value ?? 0),
    );
  }

  List<Widget> _items() {
    final value = data;
    if (value is I18nMessages) {
      return value.messages.entries
          .map((item) => _Card(title: item.key, subtitle: item.value))
          .toList();
    }
    if (value is List<AnnouncementItem>) {
      return value
          .map(
            (item) => _Card(
              title: item.title,
              subtitle: '${item.summary}\n${item.publishedAt}',
              onTap: () => _announcement(item),
            ),
          )
          .toList();
    }
    if (value is List<CustomerServiceConversation>) {
      return value
          .map(
            (item) => _Card(
              title: item.subject,
              subtitle: '${item.status} · ${item.createdAt}',
            ),
          )
          .toList();
    }
    if (value is List<FavoriteItem>) {
      return value
          .map(
            (item) => _Card(
              title: item.title,
              subtitle: item.summary,
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  await gateway.deleteFavorite(item.id);
                  await load();
                },
              ),
            ),
          )
          .toList();
    }
    if (value is List<I18nLocaleItem>) {
      return value
          .map(
            (item) => _Card(
              title: item.name,
              subtitle: item.code,
              onTap: () => selectLocale(item.code),
            ),
          )
          .toList();
    }
    if (value is List<MomentItem>) {
      return value
          .map(
            (item) => _Card(
              title: item.userId,
              subtitle: '${item.content}\n${item.createdAt}',
              trailing: TextButton(
                onPressed: () async {
                  await gateway.toggleMomentLike(item);
                  await load();
                },
                child: Text('${item.liked ? '已赞' : '点赞'} ${item.likeCount}'),
              ),
            ),
          )
          .toList();
    }
    if (value is List<RobotSingleItem>) {
      return value
          .map(
            (item) => _Card(
              title: item.name,
              subtitle: item.description.isEmpty
                  ? item.welcomeText
                  : item.description,
            ),
          )
          .toList();
    }
    if (value is List<SearchMessageHit>) {
      return value
          .map(
            (item) => _Card(
              title: item.senderIdentityLabel,
              subtitle:
                  '${item.content}\n${item.sentAt ?? item.conversationId}',
            ),
          )
          .toList();
    }
    if (value is List<StickerPackItem>) {
      return value
          .map(
            (item) => _Card(
              title: item.name,
              subtitle: item.description,
              onTap: () => selectStickerPack(item.id),
            ),
          )
          .toList();
    }
    return const [
      Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: Text('当前模块暂无业务数据')),
      ),
    ];
  }

  Future<void> _announcement(AnnouncementItem item) async {
    try {
      final detail = await gateway.fetchAnnouncement(item.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(detail.item.title),
          content: SingleChildScrollView(child: Text(detail.content)),
          actions: [
            if (detail.readAckRequired && !detail.item.isRead)
              TextButton(
                onPressed: () async {
                  await gateway.acknowledgeAnnouncement(item.id);
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('确认已读'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      await load();
    } catch (value) {
      if (mounted) setState(() => error = value.toString());
    }
  }
}

final class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
  });
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: trailing,
      onTap: onTap,
    ),
  );
}

final class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.retry});
  final String message;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 48),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    ),
  );
}
