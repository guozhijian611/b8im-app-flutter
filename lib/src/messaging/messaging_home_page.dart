import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../discovery/tenant_config.dart';
import '../im/app_im_connection.dart';
import '../media/app_media_picker.dart';
import '../media/app_media_service.dart';
import '../session/app_session.dart';
import 'app_im_models.dart';
import 'app_messaging_service.dart';

final class MessagingHomePage extends StatefulWidget {
  const MessagingHomePage({
    super.key,
    required this.tenant,
    required this.session,
    required this.im,
    required this.messaging,
    required this.media,
    required this.mediaPicker,
    this.beforeMediaUpload,
    this.onOpenContacts,
    this.onUnreadChanged,
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppImRuntime im;
  final AppMessagingGateway messaging;
  final AppMediaGateway media;
  final AppMediaPickerGateway mediaPicker;
  final Future<void> Function(int size)? beforeMediaUpload;
  final VoidCallback? onOpenContacts;
  final ValueChanged<int>? onUnreadChanged;

  @override
  State<MessagingHomePage> createState() => _MessagingHomePageState();
}

final class _MessagingHomePageState extends State<MessagingHomePage> {
  final TextEditingController _searchController = TextEditingController();
  StreamSubscription<AppImEvent>? _eventSubscription;
  List<AppImConversation> _conversations = const [];
  String? _error;
  bool _loading = true;
  late AppImConnectionStatus _connectionStatus;

  @override
  void initState() {
    super.initState();
    _connectionStatus = widget.im.connectionStatus;
    _eventSubscription = widget.im.events.listen(
      (event) {
        if (event.connectionStatus case final status?) {
          if (mounted) setState(() => _connectionStatus = status);
        }
        if (event.command == 'push' ||
            event.command == 'send_ack' ||
            event.command == 'sync') {
          unawaited(_load(showSpinner: false));
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = error.toString());
      },
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (showSpinner && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final conversations = await widget.messaging.fetchConversations(
        tenant: widget.tenant,
        session: widget.session,
      );
      if (mounted) {
        setState(() {
          _conversations = conversations;
          _error = null;
        });
        widget.onUnreadChanged?.call(
          conversations.fold(0, (total, item) => total + item.unreadCount),
        );
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (showSpinner && mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openConversation(AppImConversation conversation) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ConversationPage(
          tenant: widget.tenant,
          session: widget.session,
          im: widget.im,
          messaging: widget.messaging,
          media: widget.media,
          mediaPicker: widget.mediaPicker,
          beforeMediaUpload: widget.beforeMediaUpload,
          conversation: conversation,
        ),
      ),
    );
    if (mounted) await _load(showSpinner: false);
  }

  Future<void> _reconnect() async {
    try {
      await widget.im.reconnect();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyword = _searchController.text.trim().toLowerCase();
    final visibleConversations = keyword.isEmpty
        ? _conversations
        : _conversations
              .where((conversation) {
                return conversation.title.toLowerCase().contains(keyword) ||
                    conversation.lastMessageSummary.toLowerCase().contains(
                      keyword,
                    );
              })
              .toList(growable: false);
    final content = switch ((_loading, _error, visibleConversations.isEmpty)) {
      (true, _, _) => const Center(child: CircularProgressIndicator()),
      (false, final String error, _) => _MessagingError(
        message: error,
        onRetry: _load,
      ),
      (false, null, true) => B8EmptyState(
        icon: Icons.chat_bubble_outline_rounded,
        title: keyword.isEmpty ? '暂无会话' : '没有找到相关会话',
        message: keyword.isEmpty ? '从通讯录选择联系人，开始第一段对话' : '请尝试其他关键词',
        action: keyword.isEmpty && widget.onOpenContacts != null
            ? TextButton.icon(
                onPressed: widget.onOpenContacts,
                icon: const Icon(Icons.contacts_outlined),
                label: const Text('打开通讯录'),
              )
            : null,
      ),
      _ => RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          key: const ValueKey('conversation-list'),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          itemCount: visibleConversations.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final conversation = visibleConversations[index];
            return _ConversationCard(
              key: ValueKey('conversation-${conversation.conversationId}'),
              conversation: conversation,
              onTap: () => _openConversation(conversation),
            );
          },
        ),
      ),
    };
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('B8 IM'),
        actions: [
          IconButton(
            key: const ValueKey('start-chat-action'),
            onPressed: widget.onOpenContacts,
            icon: const Icon(Icons.add_rounded),
            tooltip: '发起聊天',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_connectionStatus != AppImConnectionStatus.connected)
            _ConnectionBanner(
              status: _connectionStatus,
              onReconnect: _reconnect,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
            child: TextField(
              key: const ValueKey('conversation-search'),
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: '搜索联系人、群组、消息',
                prefixIcon: Icon(Icons.search_rounded),
                isDense: true,
              ),
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }
}

final class _ConversationCard extends StatelessWidget {
  const _ConversationCard({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  final AppImConversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        onTap: onTap,
        leading: Badge(
          isLabelVisible: conversation.unreadCount > 0,
          label: Text(
            conversation.unreadCount > 99
                ? '99+'
                : '${conversation.unreadCount}',
          ),
          child: B8Avatar(
            label: conversation.title,
            imageUrl: conversation.avatarUrl,
            size: 50,
            backgroundColor: const Color(0xFFBCEBD2),
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              _shortTime(conversation.lastMessageTime),
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: B8Colors.muted),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  conversation.lastMessageSummary.isEmpty
                      ? '暂无消息'
                      : conversation.lastMessageSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: B8Colors.muted),
                ),
              ),
              if (conversation.isMuted)
                const Icon(
                  Icons.volume_off_outlined,
                  size: 16,
                  color: B8Colors.muted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class ConversationPage extends StatefulWidget {
  const ConversationPage({
    super.key,
    required this.tenant,
    required this.session,
    required this.im,
    required this.messaging,
    required this.conversation,
    required this.media,
    required this.mediaPicker,
    this.beforeMediaUpload,
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppImRuntime im;
  final AppMessagingGateway messaging;
  final AppImConversation conversation;
  final AppMediaGateway media;
  final AppMediaPickerGateway mediaPicker;
  final Future<void> Function(int size)? beforeMediaUpload;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

final class _ConversationPageState extends State<ConversationPage> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Map<String, AppImMessage> _messages = {};
  final Map<String, AppImDeliveryStatus> _deliveryStatuses = {};
  final Set<String> _readAcknowledged = {};
  StreamSubscription<AppImEvent>? _eventSubscription;
  String? _error;
  int _beforeSeq = 0;
  bool _hasMoreBefore = false;
  bool _loading = true;
  bool _loadingOlder = false;
  bool _sending = false;
  late AppImConnectionStatus _connectionStatus;
  String? _resolvedConversationId;

  String get _conversationId =>
      _resolvedConversationId ?? widget.conversation.conversationId;

  String get _requestConversationId =>
      widget.conversation.isVirtual && _resolvedConversationId == null
      ? ''
      : _conversationId;

  List<AppImMessage> get _orderedMessages {
    final values = _messages.values.toList();
    values.sort((left, right) => left.messageSeq.compareTo(right.messageSeq));
    return values;
  }

  @override
  void initState() {
    super.initState();
    if (!widget.conversation.isVirtual) {
      _resolvedConversationId = widget.conversation.conversationId;
    }
    _connectionStatus = widget.im.connectionStatus;
    _eventSubscription = widget.im.events.listen(
      (event) {
        if (event.connectionStatus case final status?) {
          if (mounted) setState(() => _connectionStatus = status);
        }
        if (event.receipt case final receipt?) {
          _applyReceipt(receipt);
        }
        if (event.conversationRead case final read?) {
          _applyConversationRead(read);
        }
        final message = event.message;
        if (message != null &&
            (message.conversationId == _conversationId ||
                (widget.conversation.isVirtual &&
                    message.senderId ==
                        widget.conversation.peerUser?.userId))) {
          _merge([message]);
          if (event.command == 'push') unawaited(_markRead());
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = error.toString());
      },
    );
    unawaited(_loadInitial());
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _composer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadInitial() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.messaging.fetchMessages(
        tenant: widget.tenant,
        session: widget.session,
        conversationId: _requestConversationId,
        peerUserId: _resolvedConversationId == null
            ? widget.conversation.peerUser?.userId ?? ''
            : '',
      );
      _merge(page.messages, notify: false);
      if (mounted) {
        setState(() {
          _beforeSeq = page.nextBeforeSeq;
          _hasMoreBefore = page.hasMoreBefore;
        });
      }
      await _markRead();
      _scrollToBottom();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreBefore || _beforeSeq <= 0) return;
    setState(() => _loadingOlder = true);
    try {
      final page = await widget.messaging.fetchMessages(
        tenant: widget.tenant,
        session: widget.session,
        conversationId: _requestConversationId,
        peerUserId: _resolvedConversationId == null
            ? widget.conversation.peerUser?.userId ?? ''
            : '',
        beforeSeq: _beforeSeq,
      );
      _merge(page.messages, notify: false);
      if (mounted) {
        setState(() {
          _beforeSeq = page.nextBeforeSeq;
          _hasMoreBefore = page.hasMoreBefore;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _markRead() async {
    if (_messages.isEmpty) return;
    final conversationId = _resolvedConversationId;
    if (conversationId == null || conversationId.isEmpty) return;
    try {
      final messages = _orderedMessages;
      if (widget.im.isConnected) {
        for (final message in messages) {
          if (message.senderId == widget.session.user.userId ||
              _readAcknowledged.contains(message.messageId)) {
            continue;
          }
          await widget.im.acknowledge(
            messageId: message.messageId,
            status: AppImDeliveryStatus.read,
          );
          _readAcknowledged.add(message.messageId);
        }
        await widget.im.markConversationRead(
          conversationId: conversationId,
          lastReadMessageId: messages.last.messageId,
        );
      } else {
        await widget.messaging.markRead(
          tenant: widget.tenant,
          session: widget.session,
          conversationId: conversationId,
        );
      }
    } on Object catch (error) {
      try {
        await widget.messaging.markRead(
          tenant: widget.tenant,
          session: widget.session,
          conversationId: conversationId,
        );
      } on Object {
        if (mounted) setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final message = await widget.im.sendText(
        conversationType: widget.conversation.conversationType,
        conversationId: _resolvedConversationId,
        toUserId: widget.conversation.peerUser?.userId,
        text: text,
      );
      _composer.clear();
      _merge([message]);
      _scrollToBottom();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendMedia(AppMediaKind kind) async {
    if (_sending) return;
    final picked = await widget.mediaPicker.pick(kind);
    if (picked == null || !mounted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.beforeMediaUpload?.call(picked.size);
      final uploaded = await widget.media.upload(
        tenant: widget.tenant,
        session: widget.session,
        kind: kind,
        filePath: picked.path,
        filename: picked.filename,
        size: picked.size,
        mimeType: picked.mimeType,
      );
      final message = await widget.im.sendAsset(
        conversationType: widget.conversation.conversationType,
        conversationId: _resolvedConversationId,
        toUserId: widget.conversation.peerUser?.userId,
        messageType: kind.messageType,
        fileId: uploaded.fileId,
      );
      _merge([message]);
      _scrollToBottom();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _showAttachmentPicker() async {
    final kind = await showModalBottomSheet<AppMediaKind>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              key: const ValueKey('pick-image'),
              leading: const Icon(Icons.image_outlined),
              title: const Text('发送图片'),
              onTap: () => Navigator.pop(context, AppMediaKind.image),
            ),
            ListTile(
              key: const ValueKey('pick-file'),
              leading: const Icon(Icons.attach_file_rounded),
              title: const Text('发送文件'),
              onTap: () => Navigator.pop(context, AppMediaKind.file),
            ),
          ],
        ),
      ),
    );
    if (kind != null && mounted) await _sendMedia(kind);
  }

  Future<void> _reconnect() async {
    try {
      await widget.im.reconnect();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  void _merge(Iterable<AppImMessage> messages, {bool notify = true}) {
    for (final message in messages) {
      if (_resolvedConversationId == null &&
          message.conversationId.isNotEmpty) {
        _resolvedConversationId = message.conversationId;
      }
      _messages[message.messageId] = message;
      if (message.deliveryStatus case final status?) {
        _advanceDelivery(message.messageId, status);
      }
    }
    if (notify && mounted) setState(() {});
  }

  void _applyReceipt(AppImReceipt receipt) {
    if (receipt.conversationId != _conversationId ||
        receipt.senderId != widget.session.user.userId) {
      return;
    }
    _advanceDelivery(receipt.messageId, receipt.status);
    if (mounted) setState(() {});
  }

  void _applyConversationRead(AppImConversationReadState read) {
    if (read.conversationId != _conversationId ||
        read.userId == widget.session.user.userId) {
      return;
    }
    for (final message in _messages.values) {
      if (message.senderId == widget.session.user.userId &&
          message.messageSeq <= read.lastReadSeq) {
        _advanceDelivery(message.messageId, AppImDeliveryStatus.read);
      }
    }
    if (mounted) setState(() {});
  }

  void _advanceDelivery(String messageId, AppImDeliveryStatus next) {
    final current = _deliveryStatuses[messageId];
    if (current == null || next.rank > current.rank) {
      _deliveryStatuses[messageId] = next;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = _orderedMessages;
    return Scaffold(
      appBar: AppBar(title: Text(widget.conversation.title)),
      body: SafeArea(
        child: Column(
          children: [
            if (_connectionStatus != AppImConnectionStatus.connected)
              _ConnectionBanner(
                status: _connectionStatus,
                onReconnect: _reconnect,
              ),
            if (_error case final error?)
              MaterialBanner(
                content: Text(error),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      key: const ValueKey('message-list'),
                      controller: _scrollController,
                      padding: const EdgeInsets.all(14),
                      itemCount: messages.length + (_hasMoreBefore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (_hasMoreBefore && index == 0) {
                          return Center(
                            child: TextButton(
                              key: const ValueKey('load-older-messages'),
                              onPressed: _loadingOlder ? null : _loadOlder,
                              child: Text(_loadingOlder ? '加载中…' : '加载更早消息'),
                            ),
                          );
                        }
                        final offset = _hasMoreBefore ? 1 : 0;
                        final message = messages[index - offset];
                        return _MessageBubble(
                          key: ValueKey('message-${message.messageId}'),
                          message: message,
                          outgoing:
                              message.senderId == widget.session.user.userId,
                          deliveryStatus: _deliveryStatuses[message.messageId],
                          tenant: widget.tenant,
                          session: widget.session,
                          media: widget.media,
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('attach-media'),
                    onPressed:
                        _sending ||
                            _connectionStatus != AppImConnectionStatus.connected
                        ? null
                        : _showAttachmentPicker,
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    tooltip: '图片或文件',
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('message-composer'),
                      controller: _composer,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: '输入消息',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const ValueKey('send-message'),
                    onPressed:
                        _sending ||
                            _connectionStatus != AppImConnectionStatus.connected
                        ? null
                        : _send,
                    icon: _sending
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                    tooltip: '发送',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.outgoing,
    required this.deliveryStatus,
    required this.tenant,
    required this.session,
    required this.media,
  });

  final AppImMessage message;
  final bool outgoing;
  final AppImDeliveryStatus? deliveryStatus;
  final TenantConfig tenant;
  final AppSession session;
  final AppMediaGateway media;

  @override
  Widget build(BuildContext context) {
    final foreground = outgoing ? Colors.white : B8Colors.text;
    final detail = outgoing ? Colors.white70 : B8Colors.muted;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: outgoing ? B8Colors.primary : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(outgoing ? 18 : 5),
            bottomRight: Radius.circular(outgoing ? 5 : 18),
          ),
        ),
        child: IconTheme(
          data: IconThemeData(color: foreground),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: foreground),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!outgoing && message.senderUser != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      message.senderUser!.displayName,
                      style: TextStyle(color: detail, fontSize: 11),
                    ),
                  ),
                if (message.messageType == 2 || message.messageType == 3)
                  _AssetMessageContent(
                    message: message,
                    tenant: tenant,
                    session: session,
                    media: media,
                  )
                else
                  Text(
                    message.displayText,
                    style: TextStyle(color: foreground),
                  ),
                const SizedBox(height: 3),
                Text(
                  _shortTime(message.createTime),
                  style: TextStyle(color: detail, fontSize: 11),
                ),
                if (outgoing && deliveryStatus != null)
                  Text(
                    deliveryStatus!.label,
                    key: ValueKey('delivery-${message.messageId}'),
                    style: TextStyle(color: detail, fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _AssetMessageContent extends StatefulWidget {
  const _AssetMessageContent({
    required this.message,
    required this.tenant,
    required this.session,
    required this.media,
  });

  final AppImMessage message;
  final TenantConfig tenant;
  final AppSession session;
  final AppMediaGateway media;

  @override
  State<_AssetMessageContent> createState() => _AssetMessageContentState();
}

final class _AssetMessageContentState extends State<_AssetMessageContent> {
  Future<Uri>? _imageUrl;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    if (widget.message.messageType == 2) _imageUrl = _resolve();
  }

  Future<Uri> _resolve() => widget.media.resolve(
    tenant: widget.tenant,
    session: widget.session,
    fileId: widget.message.assetFileId,
    conversationId: widget.message.conversationId,
    messageId: widget.message.messageId,
  );

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final path = await widget.media.download(
        tenant: widget.tenant,
        session: widget.session,
        fileId: widget.message.assetFileId,
        conversationId: widget.message.conversationId,
        messageId: widget.message.messageId,
        filename: widget.message.assetName,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已下载到 $path')));
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.message.messageType == 2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FutureBuilder<Uri>(
            future: _imageUrl,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return TextButton.icon(
                  onPressed: () => setState(() => _imageUrl = _resolve()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('图片加载失败，重试'),
                );
              }
              if (!snapshot.hasData) {
                return const SizedBox.square(
                  dimension: 42,
                  child: CircularProgressIndicator(),
                );
              }
              return ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  snapshot.data.toString(),
                  width: 220,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: 220,
                    height: 100,
                    child: Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              );
            },
          ),
          IconButton(
            key: ValueKey('download-${widget.message.messageId}'),
            onPressed: _downloading ? null : _download,
            icon: _downloading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
            tooltip: '下载图片',
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.insert_drive_file_outlined),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.message.assetName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _formatBytes(widget.message.assetSize),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
        IconButton(
          key: ValueKey('download-${widget.message.messageId}'),
          onPressed: _downloading ? null : _download,
          icon: _downloading
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined),
          tooltip: '下载文件',
        ),
      ],
    );
  }
}

final class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.status, required this.onReconnect});

  final AppImConnectionStatus status;
  final Future<void> Function() onReconnect;

  @override
  Widget build(BuildContext context) {
    final text = switch (status) {
      AppImConnectionStatus.connecting => '正在连接 IM…',
      AppImConnectionStatus.reconnecting => '网络已断开，正在恢复离线消息…',
      AppImConnectionStatus.closed => 'IM 连接已关闭',
      AppImConnectionStatus.connected => '',
    };
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.cloud_off_outlined),
        title: Text(text),
        trailing: status == AppImConnectionStatus.closed
            ? null
            : TextButton(
                key: const ValueKey('reconnect-im'),
                onPressed: onReconnect,
                child: const Text('立即重连'),
              ),
      ),
    );
  }
}

final class _MessagingError extends StatelessWidget {
  const _MessagingError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = -1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 1 : 2)} ${units[unit]}';
}

String _shortTime(String value) {
  if (value.length >= 16) return value.substring(5, 16);
  return value;
}
