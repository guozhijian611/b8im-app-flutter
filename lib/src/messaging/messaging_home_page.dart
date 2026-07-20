import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../discovery/tenant_config.dart';
import '../im/app_im_connection.dart';
import '../media/app_media_picker.dart';
import '../media/app_media_service.dart';
import '../qr_login/app_qr_login_service.dart';
import '../qr_login/web_login_scanner_page.dart';
import '../session/app_session.dart';
import 'app_im_models.dart';
import 'app_messaging_service.dart';

String _identityKey(int organization, String userId) =>
    '$organization:${userId.trim()}';

final class MessagingHomePage extends StatefulWidget {
  const MessagingHomePage({
    super.key,
    required this.tenant,
    required this.session,
    required this.im,
    required this.messaging,
    required this.media,
    required this.mediaPicker,
    required this.qrLogin,
    this.qrScannerFactory,
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
  final AppQrLoginGateway qrLogin;
  final AppQrCodeScannerFactory? qrScannerFactory;
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
  late final AppImAccessEventGate _accessGate;
  final Set<String> _revokedPeerIdentities = {};
  final Set<String> _pendingRestorePeerIdentities = {};
  final Map<String, AppImMessage> _pendingDeliveryMessages = {};
  final Set<String> _deliveryAckInFlight = {};
  int _accessEpoch = 0;

  AppImConversationIdentityContext _identityFor(
    AppImConversation conversation,
  ) => AppImConversationIdentityContext(
    organization: widget.session.organization,
    userId: widget.session.user.userId,
    conversationId: conversation.conversationId,
    conversationType: conversation.conversationType,
    peerOrganization: conversation.peerUser?.organization,
    peerUserId: conversation.peerUser?.userId,
  );

  @override
  void initState() {
    super.initState();
    _connectionStatus = widget.im.connectionStatus;
    _accessGate = AppImAccessEventGate(
      widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    _accessGate.reconcileConnectionSnapshot(
      current: widget.im.bootstrap.crossOrgAccessSnapshotId,
      highestPositive: widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    _eventSubscription = widget.im.events.listen(
      (event) {
        if (event.connectionStatus case final status?) {
          if (mounted) setState(() => _connectionStatus = status);
          if (status == AppImConnectionStatus.connected) {
            final snapshot = _accessGate.reconcileConnectionSnapshot(
              current: widget.im.bootstrap.crossOrgAccessSnapshotId,
              highestPositive:
                  widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
            );
            if (snapshot == AppImAccessSnapshotObservation.invalid ||
                snapshot == AppImAccessSnapshotObservation.stale ||
                _accessGate.isCrossOrganizationFailClosed) {
              _failCloseCrossOrganization();
            } else {
              _accessEpoch += 1;
              _hideCrossOrganizationConversations();
              _revokedPeerIdentities.clear();
              _pendingRestorePeerIdentities.clear();
              for (final accessChanged in widget.im.recentAccessChanges) {
                _applyAccessChanged(accessChanged);
              }
              unawaited(_load(showSpinner: false));
            }
          }
        }
        if (event.accessChanged case final accessChanged?) {
          _applyAccessChanged(accessChanged);
        }
        if (event.message case final message?) {
          if (event.command == 'push' || event.command == 'sync') {
            _queueDelivery(message);
          }
        }
        if (event.command == 'push' ||
            event.command == 'send_ack' ||
            event.command == 'sync' ||
            event.command == 'ack' ||
            event.command == 'conversation_read' ||
            event.mutation != null) {
          unawaited(_load(showSpinner: false));
        }
      },
      onError: (Object error) {
        if (isAppImAccessSnapshotFailure(error)) {
          _failCloseCrossOrganization(error: error);
        } else if (mounted) {
          setState(() => _error = error.toString());
        }
      },
    );
    for (final accessChanged in widget.im.recentAccessChanges) {
      _applyAccessChanged(accessChanged);
    }
    if (_accessGate.isCrossOrganizationFailClosed) {
      _failCloseCrossOrganization();
    }
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({
    bool showSpinner = true,
    String? restoringPeerKey,
  }) async {
    final accessEpoch = _accessEpoch;
    final syncCursor = widget.im.bootstrap.nextGlobalSeq;
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
      if (accessEpoch != _accessEpoch) return;
      widget.im.registerConversationIdentities(
        conversations.where((item) => !item.isVirtual).map(_identityFor),
      );
      if (restoringPeerKey != null) {
        _pendingRestorePeerIdentities.add(restoringPeerKey);
      }
      final confirmedRestoreKeys = conversations
          .map((item) => item.peerUser)
          .whereType<AppImUserSummary>()
          .map((peer) => _identityKey(peer.organization, peer.userId))
          .where(_pendingRestorePeerIdentities.contains)
          .toSet();
      _revokedPeerIdentities.removeAll(confirmedRestoreKeys);
      _pendingRestorePeerIdentities.removeAll(confirmedRestoreKeys);
      final visibleConversations = conversations
          .where((item) {
            final peer = item.peerUser;
            return peer == null ||
                ((peer.organization == widget.session.organization ||
                        !_accessGate.isCrossOrganizationFailClosed) &&
                    !_revokedPeerIdentities.contains(
                      _identityKey(peer.organization, peer.userId),
                    ));
          })
          .toList(growable: false);
      if (mounted) {
        setState(() {
          _conversations = visibleConversations;
          _error = null;
        });
        widget.onUnreadChanged?.call(
          visibleConversations.fold(
            0,
            (total, item) => total + item.unreadCount,
          ),
        );
      }
      final consumed = await widget.im.consumeGlobalSync(
        nextGlobalSeq: syncCursor,
        consumer: (messages) async {
          if (accessEpoch != _accessEpoch) {
            throw StateError('SYNC 消费期间访问 epoch 已变化');
          }
          for (final message in messages) {
            _queueDelivery(message);
          }
        },
      );
      if (!consumed || accessEpoch != _accessEpoch) return;
      unawaited(_acknowledgeAuthoritativeDeliveries(conversations));
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (showSpinner && mounted && accessEpoch == _accessEpoch) {
        setState(() => _loading = false);
      }
    }
  }

  void _applyAccessChanged(AppImConversationAccessChanged accessChanged) {
    if (!appImSameIdentity(
          accessChanged.targetOrganization,
          accessChanged.targetUserId,
          widget.session.organization,
          widget.session.user.userId,
        ) ||
        _accessGate.observe(accessChanged) != AppImAccessEventDecision.apply) {
      return;
    }
    final peerKey = _identityKey(
      accessChanged.peerOrganization,
      accessChanged.peerUserId,
    );
    _accessEpoch += 1;
    if (accessChanged.allowed) {
      _pendingRestorePeerIdentities.add(peerKey);
      _revokedPeerIdentities.add(peerKey);
      _pendingDeliveryMessages.removeWhere(
        (_, message) =>
            message.conversationId == accessChanged.conversationId ||
            appImSameIdentity(
              message.senderOrganization,
              message.senderId,
              accessChanged.peerOrganization,
              accessChanged.peerUserId,
            ),
      );
      _hidePeerConversation(accessChanged.conversationId, peerKey);
      unawaited(_load(showSpinner: false, restoringPeerKey: peerKey));
      return;
    } else {
      _pendingRestorePeerIdentities.remove(peerKey);
      _revokedPeerIdentities.add(peerKey);
      _pendingDeliveryMessages.removeWhere(
        (_, message) =>
            message.conversationId == accessChanged.conversationId ||
            appImSameIdentity(
              message.senderOrganization,
              message.senderId,
              accessChanged.peerOrganization,
              accessChanged.peerUserId,
            ),
      );
      _hidePeerConversation(accessChanged.conversationId, peerKey);
    }
    unawaited(_load(showSpinner: false));
  }

  void _hidePeerConversation(String conversationId, String peerKey) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _conversations = _conversations
          .where(
            (item) =>
                item.conversationId != conversationId &&
                (item.peerUser == null ||
                    _identityKey(
                          item.peerUser!.organization,
                          item.peerUser!.userId,
                        ) !=
                        peerKey),
          )
          .toList(growable: false);
    });
    widget.onUnreadChanged?.call(
      _conversations.fold(0, (total, item) => total + item.unreadCount),
    );
  }

  void _queueDelivery(AppImMessage message) {
    if (appImSameIdentity(
      message.senderOrganization,
      message.senderId,
      widget.session.organization,
      widget.session.user.userId,
    )) {
      return;
    }
    _pendingDeliveryMessages[message.messageId] = message;
    if (_pendingDeliveryMessages.length > 256) {
      _pendingDeliveryMessages.remove(_pendingDeliveryMessages.keys.first);
    }
  }

  Future<void> _acknowledgeAuthoritativeDeliveries(
    List<AppImConversation> conversations,
  ) async {
    final accessEpoch = _accessEpoch;
    final byId = {
      for (final conversation in conversations)
        conversation.conversationId: conversation,
    };
    for (final entry in List.of(_pendingDeliveryMessages.entries)) {
      if (accessEpoch != _accessEpoch) return;
      if (_deliveryAckInFlight.contains(entry.key)) continue;
      final message = entry.value;
      final conversation = byId[message.conversationId];
      if (conversation == null) continue;
      final peer = conversation.peerUser;
      final isCrossOrganization =
          conversation.conversationType == 1 &&
          peer != null &&
          peer.organization != widget.session.organization;
      if ((isCrossOrganization && _accessGate.isCrossOrganizationFailClosed) ||
          (peer != null &&
              _revokedPeerIdentities.contains(
                _identityKey(peer.organization, peer.userId),
              ))) {
        _pendingDeliveryMessages.remove(entry.key);
        continue;
      }
      final context = _identityFor(conversation);
      if (!context.acceptsMessage(message)) {
        _pendingDeliveryMessages.remove(entry.key);
        continue;
      }
      _deliveryAckInFlight.add(entry.key);
      try {
        await widget.im.acknowledge(
          message: message,
          status: AppImDeliveryStatus.delivered,
          identity: context,
        );
        if (accessEpoch != _accessEpoch) return;
        _pendingDeliveryMessages.remove(entry.key);
      } on Object {
        // 保留待确认项，连接恢复或会话列表刷新后重试。
      } finally {
        _deliveryAckInFlight.remove(entry.key);
      }
    }
  }

  void _hideCrossOrganizationConversations() {
    _pendingDeliveryMessages.removeWhere(
      (_, message) => message.senderOrganization != widget.session.organization,
    );
    final visible = _conversations
        .where(
          (item) =>
              item.peerUser == null ||
              item.peerUser!.organization == widget.session.organization,
        )
        .toList(growable: false);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _conversations = visible;
    });
    widget.onUnreadChanged?.call(
      visible.fold(0, (total, item) => total + item.unreadCount),
    );
  }

  void _failCloseCrossOrganization({Object? error}) {
    _accessEpoch += 1;
    _accessGate.resetSnapshot('0');
    _pendingRestorePeerIdentities.clear();
    _pendingDeliveryMessages.removeWhere(
      (_, message) => message.senderOrganization != widget.session.organization,
    );
    final visible = _conversations
        .where(
          (item) =>
              item.peerUser == null ||
              item.peerUser!.organization == widget.session.organization,
        )
        .toList(growable: false);
    if (mounted) {
      setState(() {
        _loading = false;
        _conversations = visible;
        if (error != null) _error = error.toString();
      });
      widget.onUnreadChanged?.call(
        visible.fold(0, (total, item) => total + item.unreadCount),
      );
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

  Future<void> _openWebLoginScanner() async {
    final confirmed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WebLoginScannerPage(
          tenant: widget.tenant,
          session: widget.session,
          gateway: widget.qrLogin,
          scanner: widget.qrScannerFactory?.call(),
        ),
      ),
    );
    if (confirmed == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已确认 Web 登录')));
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
          IconButton(
            key: const ValueKey('open-web-login-scanner'),
            onPressed: _openWebLoginScanner,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            tooltip: '扫一扫',
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
  final Map<String, int> _lastMessageChangeSequences = {};
  StreamSubscription<AppImEvent>? _eventSubscription;
  Timer? _typingExpiry;
  String? _typingLabel;
  DateTime? _lastTypingSentAt;
  String? _error;
  int _beforeSeq = 0;
  bool _hasMoreBefore = false;
  bool _loading = true;
  bool _loadingOlder = false;
  bool _sending = false;
  late AppImConnectionStatus _connectionStatus;
  late final AppImAccessEventGate _accessGate;
  String? _resolvedConversationId;
  int _lastConversationChangeSequence = 0;
  int _localReadSequence = 0;
  bool _accessRevoked = false;
  bool _accessDeniedByEvent = false;
  bool _authoritativeAccessRefreshInFlight = false;
  int _accessEpoch = 0;
  Future<void> _mutationQueue = Future<void>.value();

  String get _conversationId =>
      _resolvedConversationId ?? widget.conversation.conversationId;

  String get _requestConversationId =>
      widget.conversation.isVirtual && _resolvedConversationId == null
      ? ''
      : _conversationId;

  bool get _isCrossOrganizationConversation {
    final peer = widget.conversation.peerUser;
    return widget.conversation.conversationType == 1 &&
        peer != null &&
        peer.organization != widget.session.organization;
  }

  bool _isCurrentUserMessage(AppImMessage message) =>
      message.senderOrganization == widget.session.organization &&
      message.senderId == widget.session.user.userId;

  bool _isVirtualPeerMessage(AppImMessage message) =>
      message.senderOrganization ==
          widget.conversation.peerUser?.organization &&
      message.senderId == widget.conversation.peerUser?.userId;

  AppImConversationIdentityContext _securityContext(String conversationId) =>
      AppImConversationIdentityContext(
        organization: widget.session.organization,
        userId: widget.session.user.userId,
        conversationId: conversationId,
        conversationType: widget.conversation.conversationType,
        peerOrganization: widget.conversation.peerUser?.organization,
        peerUserId: widget.conversation.peerUser?.userId,
      );

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
    _accessGate = AppImAccessEventGate(
      widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    _accessGate.reconcileConnectionSnapshot(
      current: widget.im.bootstrap.crossOrgAccessSnapshotId,
      highestPositive: widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
    );
    if (_resolvedConversationId case final conversationId?) {
      try {
        widget.im.registerConversationIdentities([
          _securityContext(conversationId),
        ]);
      } on Object catch (error) {
        _accessRevoked = true;
        _error = error.toString();
      }
    }
    if (_isCrossOrganizationConversation &&
        _accessGate.isCrossOrganizationFailClosed) {
      _accessRevoked = true;
      _error = '跨机构访问暂不可用';
    }
    _eventSubscription = widget.im.events.listen(
      (event) {
        if (event.connectionStatus case final status?) {
          if (mounted) setState(() => _connectionStatus = status);
          if (status != AppImConnectionStatus.connected) {
            _clearTypingState();
          }
          if (status == AppImConnectionStatus.connected &&
              _isCrossOrganizationConversation) {
            final snapshot = _accessGate.reconcileConnectionSnapshot(
              current: widget.im.bootstrap.crossOrgAccessSnapshotId,
              highestPositive:
                  widget.im.bootstrap.highestCrossOrgAccessSnapshotId,
            );
            if (snapshot == AppImAccessSnapshotObservation.invalid ||
                snapshot == AppImAccessSnapshotObservation.stale ||
                _accessGate.isCrossOrganizationFailClosed) {
              _failCloseCrossOrganization();
            } else {
              _prepareAuthoritativeAccessRefresh();
              for (final accessChanged in widget.im.recentAccessChanges) {
                _applyAccessChanged(accessChanged);
              }
              _requestAuthoritativeAccessRefresh();
            }
          }
        }
        if (event.receipt case final receipt?) {
          _applyReceipt(receipt);
        }
        if (event.conversationRead case final read?) {
          _applyConversationRead(read);
        }
        if (event.mutation case final mutation?) {
          final accessEpoch = _accessEpoch;
          _mutationQueue = _mutationQueue.then((_) async {
            if (accessEpoch != _accessEpoch) return;
            await _applyMutation(mutation);
          });
        }
        if (event.typing case final typing?) {
          _applyTyping(typing);
        }
        if (event.accessChanged case final accessChanged?) {
          _applyAccessChanged(accessChanged);
        }
        final message = event.message;
        if (!_accessRevoked &&
            message != null &&
            (message.conversationId == _conversationId ||
                (widget.conversation.isVirtual &&
                    _isVirtualPeerMessage(message)))) {
          final accepted = _merge([message]);
          if (accepted && event.command == 'push') unawaited(_markRead());
        }
      },
      onError: (Object error) {
        if (isAppImAccessSnapshotFailure(error) &&
            _isCrossOrganizationConversation) {
          _failCloseCrossOrganization(error: error);
        } else if (mounted) {
          setState(() => _error = error.toString());
        }
      },
    );
    for (final accessChanged in widget.im.recentAccessChanges) {
      _applyAccessChanged(accessChanged);
    }
    if (!_accessRevoked) unawaited(_loadInitial());
  }

  @override
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _typingExpiry?.cancel();
    _composer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _prepareAuthoritativeAccessRefresh() {
    _accessEpoch += 1;
    _accessDeniedByEvent = false;
    _authoritativeAccessRefreshInFlight = false;
    _typingExpiry?.cancel();
    _composer.clear();
    if (!mounted) return;
    setState(() {
      _accessRevoked = true;
      _messages.clear();
      _deliveryStatuses.clear();
      _readAcknowledged.clear();
      _lastMessageChangeSequences.clear();
      _lastConversationChangeSequence = 0;
      _typingLabel = null;
      _sending = false;
      _error = null;
    });
  }

  void _requestAuthoritativeAccessRefresh() {
    if (_accessDeniedByEvent ||
        _accessGate.isCrossOrganizationFailClosed ||
        _authoritativeAccessRefreshInFlight ||
        !mounted) {
      return;
    }
    _authoritativeAccessRefreshInFlight = true;
    unawaited(_loadInitial(authoritativeRestore: true));
  }

  void _clearTypingState() {
    _typingExpiry?.cancel();
    if (_typingLabel == null || !mounted) return;
    setState(() => _typingLabel = null);
  }

  String? _authoritativeConversationId(AppImMessagePage page) {
    final conversationId =
        _resolvedConversationId ??
        (page.messages.isEmpty ? null : page.messages.first.conversationId);
    if (conversationId == null) return null;
    final security = _securityContext(conversationId);
    if (page.messages.any((message) => !security.acceptsMessage(message))) {
      throw const FormatException('权威历史包含错误会话或复合身份消息');
    }
    return conversationId;
  }

  Future<void> _loadInitial({bool authoritativeRestore = false}) async {
    if (_accessRevoked && !authoritativeRestore) return;
    final accessEpoch = _accessEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.messaging.fetchMessages(
        tenant: widget.tenant,
        session: widget.session,
        conversationId: _requestConversationId,
        peerOrganization: _resolvedConversationId == null
            ? widget.conversation.peerUser?.organization ?? 0
            : 0,
        peerUserId: _resolvedConversationId == null
            ? widget.conversation.peerUser?.userId ?? ''
            : '',
      );
      if (accessEpoch != _accessEpoch ||
          (_accessRevoked && !authoritativeRestore)) {
        return;
      }
      final authoritativeConversationId = authoritativeRestore
          ? _authoritativeConversationId(page)
          : null;
      if (!authoritativeRestore) _merge(page.messages, notify: false);
      if (mounted) {
        setState(() {
          if (authoritativeRestore) {
            _accessRevoked = false;
            _resolvedConversationId ??= authoritativeConversationId;
            _messages
              ..clear()
              ..addEntries(
                page.messages.map(
                  (message) => MapEntry(message.messageId, message),
                ),
              );
            _deliveryStatuses.clear();
            for (final message in page.messages) {
              if (message.deliveryStatus case final status?) {
                _advanceDelivery(message.messageId, status);
              }
            }
          }
          _beforeSeq = page.nextBeforeSeq;
          _hasMoreBefore = page.hasMoreBefore;
        });
      }
      await _markRead();
      _scrollToBottom();
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && accessEpoch == _accessEpoch) {
        _authoritativeAccessRefreshInFlight = false;
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreBefore || _beforeSeq <= 0) return;
    final accessEpoch = _accessEpoch;
    setState(() => _loadingOlder = true);
    try {
      final page = await widget.messaging.fetchMessages(
        tenant: widget.tenant,
        session: widget.session,
        conversationId: _requestConversationId,
        peerOrganization: _resolvedConversationId == null
            ? widget.conversation.peerUser?.organization ?? 0
            : 0,
        peerUserId: _resolvedConversationId == null
            ? widget.conversation.peerUser?.userId ?? ''
            : '',
        beforeSeq: _beforeSeq,
      );
      if (_accessRevoked || accessEpoch != _accessEpoch) return;
      _merge(page.messages, notify: false);
      if (mounted) {
        setState(() {
          _beforeSeq = page.nextBeforeSeq;
          _hasMoreBefore = page.hasMoreBefore;
        });
      }
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch && !_accessRevoked) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _loadingOlder = false);
      }
    }
  }

  Future<void> _markRead() async {
    if (_accessRevoked || _messages.isEmpty) return;
    final accessEpoch = _accessEpoch;
    bool accessIsCurrent() => !_accessRevoked && accessEpoch == _accessEpoch;
    final conversationId = _resolvedConversationId;
    if (conversationId == null || conversationId.isEmpty) return;
    try {
      final messages = _orderedMessages;
      if (widget.im.isConnected) {
        for (final message in messages) {
          if (!accessIsCurrent()) return;
          if (_isCurrentUserMessage(message) ||
              _readAcknowledged.contains(message.messageId)) {
            continue;
          }
          await widget.im.acknowledge(
            message: message,
            status: AppImDeliveryStatus.read,
            identity: _securityContext(conversationId),
          );
          if (!accessIsCurrent()) return;
          _readAcknowledged.add(message.messageId);
        }
        if (!accessIsCurrent()) return;
        await widget.im.markConversationRead(
          identity: _securityContext(conversationId),
          lastReadMessage: messages.last,
        );
      } else {
        if (!accessIsCurrent()) return;
        await widget.messaging.markRead(
          tenant: widget.tenant,
          session: widget.session,
          conversationId: conversationId,
        );
      }
    } on Object catch (error) {
      if (!accessIsCurrent()) return;
      try {
        if (!accessIsCurrent()) return;
        await widget.messaging.markRead(
          tenant: widget.tenant,
          session: widget.session,
          conversationId: conversationId,
        );
      } on Object {
        if (mounted && accessIsCurrent()) {
          setState(() => _error = error.toString());
        }
      }
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending || _accessRevoked) return;
    final accessEpoch = _accessEpoch;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final message = await widget.im.sendText(
        conversationType: widget.conversation.conversationType,
        conversationId: _resolvedConversationId,
        toOrganization: widget.conversation.peerUser?.organization,
        toUserId: widget.conversation.peerUser?.userId,
        text: text,
      );
      if (!mounted || _accessRevoked || accessEpoch != _accessEpoch) return;
      _composer.clear();
      _merge([message]);
      _scrollToBottom();
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch && !_accessRevoked) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _sendMedia(AppMediaKind kind) async {
    if (_sending || _accessRevoked) return;
    final accessEpoch = _accessEpoch;
    final picked = await widget.mediaPicker.pick(kind);
    if (picked == null ||
        !mounted ||
        _accessRevoked ||
        accessEpoch != _accessEpoch) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.beforeMediaUpload?.call(picked.size);
      if (!mounted || _accessRevoked || accessEpoch != _accessEpoch) return;
      final uploaded = await widget.media.upload(
        tenant: widget.tenant,
        session: widget.session,
        kind: kind,
        filePath: picked.path,
        filename: picked.filename,
        size: picked.size,
        mimeType: picked.mimeType,
      );
      if (!mounted || _accessRevoked || accessEpoch != _accessEpoch) return;
      final message = await widget.im.sendAsset(
        conversationType: widget.conversation.conversationType,
        conversationId: _resolvedConversationId,
        toOrganization: widget.conversation.peerUser?.organization,
        toUserId: widget.conversation.peerUser?.userId,
        messageType: kind.messageType,
        fileId: uploaded.fileId,
      );
      if (!mounted || _accessRevoked || accessEpoch != _accessEpoch) return;
      _merge([message]);
      _scrollToBottom();
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch && !_accessRevoked) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && accessEpoch == _accessEpoch) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _showAttachmentPicker() async {
    if (_accessRevoked) return;
    final accessEpoch = _accessEpoch;
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
    if (kind != null &&
        mounted &&
        !_accessRevoked &&
        accessEpoch == _accessEpoch) {
      await _sendMedia(kind);
    }
  }

  void _onComposerChanged(String value) {
    if (value.trim().isEmpty ||
        _accessRevoked ||
        _connectionStatus != AppImConnectionStatus.connected) {
      return;
    }
    final conversationId = _resolvedConversationId;
    if (conversationId == null || conversationId.isEmpty) return;
    final now = DateTime.now();
    if (_lastTypingSentAt != null &&
        now.difference(_lastTypingSentAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastTypingSentAt = now;
    try {
      widget.im.sendTyping(_securityContext(conversationId));
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _sendScreenshot() async {
    final conversationId = _resolvedConversationId;
    if (_accessRevoked || conversationId == null || conversationId.isEmpty) {
      return;
    }
    final accessEpoch = _accessEpoch;
    try {
      final notice = await widget.im.sendScreenshot(
        _securityContext(conversationId),
      );
      if (!mounted || _accessRevoked || accessEpoch != _accessEpoch) return;
      if (notice != null) _merge([notice]);
    } on Object catch (error) {
      if (mounted && accessEpoch == _accessEpoch && !_accessRevoked) {
        setState(() => _error = error.toString());
      }
    }
  }

  Future<void> _showMessageActions(AppImMessage message) async {
    if (_accessRevoked || message.status != 'normal') return;
    final accessEpoch = _accessEpoch;
    final outgoing = _isCurrentUserMessage(message);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            if (outgoing && message.messageType == 1)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('编辑'),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            if (outgoing)
              ListTile(
                leading: const Icon(Icons.undo_rounded),
                title: const Text('撤回'),
                onTap: () => Navigator.pop(context, 'recall'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('仅从我的设备删除'),
              onTap: () => Navigator.pop(context, 'delete_self'),
            ),
            if (outgoing)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text('为双方删除'),
                onTap: () => Navigator.pop(context, 'delete_both'),
              ),
          ],
        ),
      ),
    );
    if (action == null ||
        !mounted ||
        _accessRevoked ||
        accessEpoch != _accessEpoch) {
      return;
    }
    bool accessIsCurrent() =>
        mounted && !_accessRevoked && accessEpoch == _accessEpoch;
    try {
      switch (action) {
        case 'edit':
          final text = await _promptEdit(message.displayText);
          if (text == null || !accessIsCurrent()) return;
          final result = await widget.im.editMessage(
            message,
            text,
            identity: _securityContext(_conversationId),
          );
          if (!accessIsCurrent()) return;
          await _applyMutationResult(result);
        case 'recall':
          if (!accessIsCurrent()) return;
          final result = await widget.im.recallMessage(
            message,
            identity: _securityContext(_conversationId),
          );
          if (!accessIsCurrent()) return;
          await _applyMutationResult(result);
          break;
        case 'delete_self':
          if (!accessIsCurrent()) return;
          final result = await widget.im.deleteMessage(
            message,
            scope: 'self',
            identity: _securityContext(_conversationId),
          );
          if (!accessIsCurrent()) return;
          await _applyMutationResult(result);
          break;
        case 'delete_both':
          if (!accessIsCurrent()) return;
          final result = await widget.im.deleteMessage(
            message,
            scope: 'both',
            identity: _securityContext(_conversationId),
          );
          if (!accessIsCurrent()) return;
          await _applyMutationResult(result);
          break;
      }
    } on Object catch (error) {
      if (accessIsCurrent()) setState(() => _error = error.toString());
    }
  }

  Future<String?> _promptEdit(String initialValue) async {
    final controller = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          key: const ValueKey('edit-message-field'),
          controller: controller,
          autofocus: true,
          maxLines: 4,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _reconnect() async {
    try {
      await widget.im.reconnect();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  bool _merge(Iterable<AppImMessage> messages, {bool notify = true}) {
    if (_accessRevoked) return false;
    var changed = false;
    for (final message in messages) {
      final expectedConversationId =
          _resolvedConversationId ??
          (widget.conversation.isVirtual
              ? message.conversationId
              : widget.conversation.conversationId);
      if (!_securityContext(expectedConversationId).acceptsMessage(message)) {
        continue;
      }
      if (_resolvedConversationId == null &&
          message.conversationId.isNotEmpty) {
        widget.im.registerConversationIdentities([
          _securityContext(message.conversationId),
        ]);
        _resolvedConversationId = message.conversationId;
      }
      _messages[message.messageId] = message;
      changed = true;
      if (message.deliveryStatus case final status?) {
        _advanceDelivery(message.messageId, status);
      }
    }
    if (changed && notify && mounted) setState(() {});
    return changed;
  }

  void _applyReceipt(AppImReceipt receipt) {
    final message = _messages[receipt.messageId];
    if (_accessRevoked ||
        message == null ||
        receipt.conversationId != _conversationId ||
        receipt.messageSeq != message.messageSeq ||
        receipt.senderOrganization != message.senderOrganization ||
        receipt.senderId != message.senderId) {
      return;
    }
    final direction = _securityContext(
      _conversationId,
    ).classifyReceipt(receipt);
    switch (direction) {
      case AppImEventDirection.peerReadsCurrent:
        _advanceDelivery(receipt.messageId, receipt.status);
        if (mounted) setState(() {});
        return;
      case AppImEventDirection.currentReadsPeer:
        if (receipt.status == AppImDeliveryStatus.read) {
          _localReadSequence = _localReadSequence < receipt.messageSeq
              ? receipt.messageSeq
              : _localReadSequence;
          _readAcknowledged.add(receipt.messageId);
        }
        return;
      case AppImEventDirection.groupMember:
        if (appImSameIdentity(
              receipt.userOrganization,
              receipt.userId,
              widget.session.organization,
              widget.session.user.userId,
            ) &&
            receipt.status == AppImDeliveryStatus.read) {
          _localReadSequence = _localReadSequence < receipt.messageSeq
              ? receipt.messageSeq
              : _localReadSequence;
          _readAcknowledged.add(receipt.messageId);
        }
        return;
      case AppImEventDirection.invalid:
        return;
    }
  }

  void _applyConversationRead(AppImConversationReadState read) {
    final lastReadMessage = _messages[read.lastReadMessageId];
    if (_accessRevoked ||
        read.conversationId != _conversationId ||
        (lastReadMessage != null &&
            read.lastReadSeq != lastReadMessage.messageSeq)) {
      return;
    }
    final direction = _securityContext(
      _conversationId,
    ).classifyConversationRead(read);
    if (direction == AppImEventDirection.invalid) return;
    if (direction == AppImEventDirection.peerReadsCurrent) {
      for (final message in _messages.values) {
        if (_isCurrentUserMessage(message) &&
            message.messageSeq <= read.lastReadSeq) {
          _advanceDelivery(message.messageId, AppImDeliveryStatus.read);
        }
      }
      if (mounted) setState(() {});
      return;
    }
    if (direction == AppImEventDirection.currentReadsPeer ||
        (direction == AppImEventDirection.groupMember &&
            appImSameIdentity(
              read.userOrganization,
              read.userId,
              widget.session.organization,
              widget.session.user.userId,
            ))) {
      _localReadSequence = _localReadSequence < read.lastReadSeq
          ? read.lastReadSeq
          : _localReadSequence;
      for (final message in _messages.values) {
        if (!_isCurrentUserMessage(message) &&
            message.messageSeq <= read.lastReadSeq) {
          _readAcknowledged.add(message.messageId);
        }
      }
    }
  }

  Future<void> _applyMutation(AppImMessageMutation mutation) async {
    if (_accessRevoked || mutation.conversationId != _conversationId) {
      return;
    }
    final security = _securityContext(_conversationId);
    if (!security.isParticipant(
      mutation.actorOrganization,
      mutation.actorUserId,
    )) {
      return;
    }
    final original = _messages[mutation.messageId];
    if (original == null) {
      await _refreshAuthoritativeHistory();
      return;
    }
    if (!security.acceptsMutation(mutation, original)) {
      return;
    }
    final sequenceDecision = classifyAppImChangeSequence(
      lastConversationSequence: _lastConversationChangeSequence,
      lastMessageSequence: _lastMessageChangeSequences[mutation.messageId] ?? 0,
      incomingSequence: mutation.changeSeq,
    );
    if (sequenceDecision == AppImChangeSequenceDecision.invalid ||
        sequenceDecision == AppImChangeSequenceDecision.stale) {
      return;
    }
    if (sequenceDecision == AppImChangeSequenceDecision.gap) {
      await _refreshAuthoritativeHistory();
      return;
    }
    if (mutation.eventType == 'message.deleted_self') {
      _messages.remove(mutation.messageId);
      _deliveryStatuses.remove(mutation.messageId);
    } else if (mutation.eventType == 'message.edited') {
      final edited = mutation.message;
      if (edited == null) return;
      _messages[mutation.messageId] = edited;
    } else if (mutation.eventType == 'message.recalled') {
      _messages[mutation.messageId] = original.copyWith(
        content: null,
        status: 'recalled',
      );
    } else if (mutation.eventType == 'message.deleted_both') {
      _messages[mutation.messageId] = original.copyWith(
        content: null,
        status: 'deleted_both',
      );
    } else {
      return;
    }
    _lastConversationChangeSequence = mutation.changeSeq;
    _lastMessageChangeSequences[mutation.messageId] = mutation.changeSeq;
    if (mounted) setState(() {});
  }

  Future<void> _applyMutationResult(AppImMutationResult result) async {
    if (_accessRevoked ||
        result.conversationId != _conversationId ||
        result.messageSeq <= 0) {
      return;
    }
    final original = _messages[result.messageId];
    if (original == null ||
        original.conversationId != result.conversationId ||
        original.messageSeq != result.messageSeq) {
      await _refreshAuthoritativeHistory();
      return;
    }
    final decision = classifyAppImChangeSequence(
      lastConversationSequence: _lastConversationChangeSequence,
      lastMessageSequence: _lastMessageChangeSequences[result.messageId] ?? 0,
      incomingSequence: result.changeSeq,
    );
    if (decision == AppImChangeSequenceDecision.invalid ||
        decision == AppImChangeSequenceDecision.stale) {
      return;
    }
    if (decision == AppImChangeSequenceDecision.gap) {
      await _refreshAuthoritativeHistory();
      return;
    }
    switch (result.command) {
      case 'edit':
        final edited = result.message;
        if (edited == null ||
            !_securityContext(_conversationId).acceptsMessage(edited) ||
            !appImSameIdentity(
              edited.senderOrganization,
              edited.senderId,
              original.senderOrganization,
              original.senderId,
            )) {
          return;
        }
        _messages[result.messageId] = edited;
      case 'recall':
        if (result.status != 'recalled') return;
        _messages[result.messageId] = original.copyWith(
          content: null,
          status: 'recalled',
        );
      case 'delete':
        if (result.scope == 'self') {
          _messages.remove(result.messageId);
          _deliveryStatuses.remove(result.messageId);
        } else if (result.scope == 'both' && result.status == 'deleted_both') {
          _messages[result.messageId] = original.copyWith(
            content: null,
            status: 'deleted_both',
          );
        } else {
          return;
        }
      default:
        return;
    }
    _lastConversationChangeSequence = result.changeSeq;
    _lastMessageChangeSequences[result.messageId] = result.changeSeq;
    if (mounted) setState(() {});
  }

  Future<void> _refreshAuthoritativeHistory() async {
    final conversationId = _resolvedConversationId;
    if (_accessRevoked ||
        conversationId == null ||
        conversationId.isEmpty ||
        !widget.im.isConnected) {
      return;
    }
    final accessEpoch = _accessEpoch;
    try {
      for (var attempt = 0; attempt < 5; attempt++) {
        var afterMessageSeq = 0;
        var afterChangeSeq = _lastConversationChangeSequence;
        String? batchSnapshotId;
        var restart = false;
        var completed = false;
        final nextMessages = <String, AppImMessage>{};
        final changes = <AppImSyncedMessageChange>[];
        for (var pageNumber = 0; pageNumber < 100; pageNumber++) {
          final page = await widget.im.syncConversation(
            identity: _securityContext(conversationId),
            afterMessageSeq: afterMessageSeq,
            afterChangeSeq: afterChangeSeq,
          );
          if (!mounted || _accessRevoked || accessEpoch != _accessEpoch) {
            return;
          }
          batchSnapshotId ??= page.crossOrgAccessSnapshotId;
          if (page.crossOrgAccessSnapshotId != batchSnapshotId) {
            restart = true;
            break;
          }
          for (final message in page.messages) {
            if (!_securityContext(conversationId).acceptsMessage(message)) {
              throw const FormatException('会话 SYNC 包含非权威复合身份消息');
            }
            nextMessages[message.messageId] = message;
          }
          changes.addAll(page.changes);
          afterMessageSeq = page.nextAfterMessageSeq;
          afterChangeSeq = page.nextAfterChangeSeq;
          if (!page.messagesHasMore && !page.changesHasMore) {
            completed = true;
            break;
          }
        }
        if (restart) continue;
        if (!completed || batchSnapshotId == null) {
          throw const AppImConnectionException('会话 SYNC 分页超过安全上限');
        }
        if (_isCrossOrganizationConversation) {
          if (batchSnapshotId == '0') {
            _failCloseCrossOrganization();
            return;
          }
          final observation = _accessGate.snapshots.observe(batchSnapshotId);
          if (observation == AppImAccessSnapshotObservation.invalid) {
            throw const AppImConnectionException(
              '会话 SYNC 访问快照无效',
              code: 'IM_ACCESS_SNAPSHOT_INVALID',
            );
          }
          if (observation == AppImAccessSnapshotObservation.stale) {
            continue;
          }
        }
        changes.sort(
          (left, right) => left.changeSeq.compareTo(right.changeSeq),
        );
        final nextMessageChanges = <String, int>{};
        for (final change in changes) {
          _applySyncedChange(
            nextMessages,
            nextMessageChanges,
            change,
            _securityContext(conversationId),
          );
        }
        if (!mounted || _accessRevoked || accessEpoch != _accessEpoch) {
          return;
        }
        setState(() {
          _messages
            ..clear()
            ..addAll(nextMessages);
          _deliveryStatuses.removeWhere(
            (messageId, _) => !nextMessages.containsKey(messageId),
          );
          for (final message in nextMessages.values) {
            if (message.deliveryStatus case final status?) {
              _advanceDelivery(message.messageId, status);
            }
          }
          _lastMessageChangeSequences
            ..clear()
            ..addAll(nextMessageChanges);
          _lastConversationChangeSequence = afterChangeSeq;
          _beforeSeq = nextMessages.values.isEmpty
              ? 0
              : nextMessages.values
                    .map((message) => message.messageSeq)
                    .reduce((left, right) => left < right ? left : right);
          _hasMoreBefore = false;
          _error = null;
        });
        return;
      }
      throw const AppImConnectionException(
        '会话 SYNC 访问快照持续变化或早于本地高水位',
        code: 'IM_ACCESS_SNAPSHOT_UNSTABLE',
      );
    } on Object catch (error) {
      if (!mounted || _accessRevoked || accessEpoch != _accessEpoch) return;
      if (isAppImAccessSnapshotFailure(error) &&
          _isCrossOrganizationConversation) {
        _failCloseCrossOrganization(error: error);
      } else {
        if (mounted) setState(() => _error = error.toString());
      }
    }
  }

  void _applySyncedChange(
    Map<String, AppImMessage> messages,
    Map<String, int> messageSequences,
    AppImSyncedMessageChange change,
    AppImConversationIdentityContext identity,
  ) {
    final previousSequence = messageSequences[change.messageId] ?? 0;
    if (change.changeSeq <= previousSequence) return;
    final original = messages[change.messageId];
    if (!identity.acceptsSyncedChange(change, original)) {
      throw const FormatException('会话 SYNC 变更复合身份无效');
    }
    switch (change.changeType) {
      case 'delete_self':
        messages.remove(change.messageId);
      case 'delete_both':
        if (original != null) {
          messages[change.messageId] = original.copyWith(
            content: null,
            status: 'deleted_both',
          );
        }
      case 'recall':
        if (original != null) {
          messages[change.messageId] = original.copyWith(
            content: null,
            status: 'recalled',
          );
        }
      case 'edit':
        if (original != null) {
          messages[change.messageId] = original.copyWith(
            content: Map<String, Object?>.from(
              change.payload['content']! as Map,
            ),
            editTime: change.payload['edit_time']! as String,
            editCount: change.payload['edit_count']! as int,
            updateTime: change.createTime,
          );
        }
      default:
        throw const FormatException('会话 SYNC 变更类型无效');
    }
    messageSequences[change.messageId] = change.changeSeq;
  }

  void _applyAccessChanged(AppImConversationAccessChanged accessChanged) {
    final peer = widget.conversation.peerUser;
    if (!appImSameIdentity(
          accessChanged.targetOrganization,
          accessChanged.targetUserId,
          widget.session.organization,
          widget.session.user.userId,
        ) ||
        peer == null ||
        !appImSameIdentity(
          accessChanged.peerOrganization,
          accessChanged.peerUserId,
          peer.organization,
          peer.userId,
        ) ||
        (!widget.conversation.isVirtual &&
            accessChanged.conversationId != _conversationId) ||
        _accessGate.observe(accessChanged) != AppImAccessEventDecision.apply) {
      return;
    }
    if (accessChanged.allowed) {
      _prepareAuthoritativeAccessRefresh();
      _requestAuthoritativeAccessRefresh();
      return;
    }
    _failCloseCrossOrganization(message: '跨机构会话访问已撤销', resetSnapshot: false);
  }

  void _failCloseCrossOrganization({
    Object? error,
    String message = '跨机构访问暂不可用',
    bool resetSnapshot = true,
  }) {
    if (resetSnapshot) _accessGate.resetSnapshot('0');
    _accessEpoch += 1;
    _accessDeniedByEvent = true;
    _authoritativeAccessRefreshInFlight = false;
    _typingExpiry?.cancel();
    _composer.clear();
    if (mounted) {
      setState(() {
        _accessRevoked = true;
        _messages.clear();
        _deliveryStatuses.clear();
        _readAcknowledged.clear();
        _lastMessageChangeSequences.clear();
        _lastConversationChangeSequence = 0;
        _typingLabel = null;
        _sending = false;
        _loading = false;
        _loadingOlder = false;
        _error = error?.toString() ?? message;
      });
    }
  }

  void _applyTyping(AppImTypingState typing) {
    if (_connectionStatus != AppImConnectionStatus.connected ||
        _accessRevoked ||
        typing.conversationId != _conversationId ||
        (typing.actorOrganization == widget.session.organization &&
            typing.actorUserId == widget.session.user.userId)) {
      return;
    }
    final peer = widget.conversation.peerUser;
    if (widget.conversation.conversationType == 1 &&
        (peer == null ||
            typing.actorOrganization != peer.organization ||
            typing.actorUserId != peer.userId)) {
      return;
    }
    if (widget.conversation.conversationType == 2 &&
        typing.actorOrganization != widget.session.organization) {
      return;
    }
    _typingExpiry?.cancel();
    if (mounted) {
      setState(() {
        _typingLabel = typing.username.isEmpty
            ? '对方正在输入…'
            : '${typing.username} 正在输入…';
      });
    }
    _typingExpiry = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _typingLabel = null);
    });
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
      appBar: AppBar(
        title: Text(widget.conversation.title),
        actions: [
          IconButton(
            key: const ValueKey('send-screenshot-notice'),
            onPressed:
                _resolvedConversationId == null ||
                    _accessRevoked ||
                    _connectionStatus != AppImConnectionStatus.connected
                ? null
                : _sendScreenshot,
            icon: const Icon(Icons.screenshot_monitor_outlined),
            tooltip: '发送截屏提示',
          ),
        ],
      ),
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
                  if (_accessRevoked)
                    TextButton(
                      onPressed:
                          _accessDeniedByEvent ||
                              _accessGate.isCrossOrganizationFailClosed
                          ? null
                          : _requestAuthoritativeAccessRefresh,
                      child: const Text('重试'),
                    )
                  else
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
                          outgoing: _isCurrentUserMessage(message),
                          deliveryStatus: _deliveryStatuses[message.messageId],
                          tenant: widget.tenant,
                          session: widget.session,
                          media: widget.media,
                          onLongPress: () => _showMessageActions(message),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            if (_typingLabel case final label?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    key: const ValueKey('typing-indicator'),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey('attach-media'),
                    onPressed:
                        _sending ||
                            _accessRevoked ||
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
                      enabled: !_accessRevoked,
                      onChanged: _onComposerChanged,
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
                            _accessRevoked ||
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
    required this.onLongPress,
  });

  final AppImMessage message;
  final bool outgoing;
  final AppImDeliveryStatus? deliveryStatus;
  final TenantConfig tenant;
  final AppSession session;
  final AppMediaGateway media;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final foreground = outgoing ? Colors.white : B8Colors.text;
    final detail = outgoing ? Colors.white70 : B8Colors.muted;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
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
