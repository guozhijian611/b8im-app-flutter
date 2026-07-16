import 'dart:async';

import 'package:flutter/material.dart';

import '../discovery/tenant_config.dart';
import '../im/app_im_connection.dart';
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
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppImRuntime im;
  final AppMessagingGateway messaging;

  @override
  State<MessagingHomePage> createState() => _MessagingHomePageState();
}

final class _MessagingHomePageState extends State<MessagingHomePage> {
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
    final content = switch ((_loading, _error, _conversations.isEmpty)) {
      (true, _, _) => const Center(child: CircularProgressIndicator()),
      (false, final String error, _) => _MessagingError(
        message: error,
        onRetry: _load,
      ),
      (false, null, true) => const Center(child: Text('暂无会话，收到或发送消息后会显示在这里')),
      _ => RefreshIndicator(
        onRefresh: _load,
        child: ListView.separated(
          key: const ValueKey('conversation-list'),
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: _conversations.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final conversation = _conversations[index];
            return ListTile(
              key: ValueKey('conversation-${conversation.conversationId}'),
              onTap: () => _openConversation(conversation),
              leading: CircleAvatar(
                backgroundImage: conversation.avatarUrl.isEmpty
                    ? null
                    : NetworkImage(conversation.avatarUrl),
                child: conversation.avatarUrl.isEmpty
                    ? Text(_initial(conversation.title))
                    : null,
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
                  if (conversation.isMuted)
                    const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(Icons.volume_off_outlined, size: 16),
                    ),
                ],
              ),
              subtitle: Text(
                conversation.lastMessageSummary.isEmpty
                    ? '暂无消息'
                    : conversation.lastMessageSummary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _shortTime(conversation.lastMessageTime),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  const SizedBox(height: 4),
                  if (conversation.unreadCount > 0)
                    Badge(
                      label: Text(
                        conversation.unreadCount > 99
                            ? '99+'
                            : '${conversation.unreadCount}',
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息'),
        actions: [
          IconButton(
            key: const ValueKey('refresh-conversations'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新会话',
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
          Expanded(child: content),
        ],
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
  });

  final TenantConfig tenant;
  final AppSession session;
  final AppImRuntime im;
  final AppMessagingGateway messaging;
  final AppImConversation conversation;

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

  List<AppImMessage> get _orderedMessages {
    final values = _messages.values.toList();
    values.sort((left, right) => left.messageSeq.compareTo(right.messageSeq));
    return values;
  }

  @override
  void initState() {
    super.initState();
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
            message.conversationId == widget.conversation.conversationId) {
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
        conversationId: widget.conversation.conversationId,
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
        conversationId: widget.conversation.conversationId,
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
          conversationId: widget.conversation.conversationId,
          lastReadMessageId: messages.last.messageId,
        );
      } else {
        await widget.messaging.markRead(
          tenant: widget.tenant,
          session: widget.session,
          conversationId: widget.conversation.conversationId,
        );
      }
    } on Object catch (error) {
      try {
        await widget.messaging.markRead(
          tenant: widget.tenant,
          session: widget.session,
          conversationId: widget.conversation.conversationId,
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
        conversationId: widget.conversation.conversationId,
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

  Future<void> _reconnect() async {
    try {
      await widget.im.reconnect();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  void _merge(Iterable<AppImMessage> messages, {bool notify = true}) {
    for (final message in messages) {
      _messages[message.messageId] = message;
      if (message.deliveryStatus case final status?) {
        _advanceDelivery(message.messageId, status);
      }
    }
    if (notify && mounted) setState(() {});
  }

  void _applyReceipt(AppImReceipt receipt) {
    if (receipt.conversationId != widget.conversation.conversationId ||
        receipt.senderId != widget.session.user.userId) {
      return;
    }
    _advanceDelivery(receipt.messageId, receipt.status);
    if (mounted) setState(() {});
  }

  void _applyConversationRead(AppImConversationReadState read) {
    if (read.conversationId != widget.conversation.conversationId ||
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
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
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
  });

  final AppImMessage message;
  final bool outgoing;
  final AppImDeliveryStatus? deliveryStatus;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: outgoing
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!outgoing && message.senderUser != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  message.senderUser!.displayName,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            Text(message.displayText),
            const SizedBox(height: 3),
            Text(
              _shortTime(message.createTime),
              style: Theme.of(context).textTheme.labelSmall,
            ),
            if (outgoing && deliveryStatus != null)
              Text(
                deliveryStatus!.label,
                key: ValueKey('delivery-${message.messageId}'),
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
      ),
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

String _initial(String value) {
  final normalized = value.trim();
  return normalized.isEmpty ? '?' : normalized.characters.first;
}

String _shortTime(String value) {
  if (value.length >= 16) return value.substring(5, 16);
  return value;
}
