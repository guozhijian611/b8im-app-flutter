import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import '../discovery/tenant_config.dart';
import '../messaging/app_im_models.dart';
import '../observability/trace_context.dart';
import '../session/app_session.dart';
import '../session/app_session_service.dart';
import '../storage/im_sync_cursor_gateway.dart';
import 'im_socket.dart';

final class AppImBootstrapSnapshot {
  const AppImBootstrapSnapshot({
    required this.clientId,
    required this.connectionSessionId,
    required this.credentialSessionId,
    required this.crossOrgAccessSnapshotId,
    required this.highestCrossOrgAccessSnapshotId,
    required this.previousGlobalSeq,
    required this.nextGlobalSeq,
    required this.syncedMessages,
  });

  final String clientId;
  final String connectionSessionId;
  final String credentialSessionId;
  final String crossOrgAccessSnapshotId;
  final String highestCrossOrgAccessSnapshotId;
  final String previousGlobalSeq;
  final String nextGlobalSeq;
  final List<AppImMessage> syncedMessages;
}

enum AppImConnectionStatus { connecting, connected, reconnecting, closed }

final class AppImEvent {
  const AppImEvent({
    required this.command,
    required this.message,
    required this.eventId,
    this.receipt,
    this.conversationRead,
    this.mutation,
    this.typing,
    this.accessChanged,
    this.connectionStatus,
  });

  final String command;
  final AppImMessage? message;
  final String? eventId;
  final AppImReceipt? receipt;
  final AppImConversationReadState? conversationRead;
  final AppImMessageMutation? mutation;
  final AppImTypingState? typing;
  final AppImConversationAccessChanged? accessChanged;
  final AppImConnectionStatus? connectionStatus;
}

abstract interface class AppImRuntime {
  AppImBootstrapSnapshot get bootstrap;
  List<AppImConversationAccessChanged> get recentAccessChanges;
  Stream<AppImEvent> get events;
  bool get isConnected;
  AppImConnectionStatus get connectionStatus;

  void registerConversationIdentities(
    Iterable<AppImConversationIdentityContext> identities,
  );

  Future<bool> consumeGlobalSync({
    required String nextGlobalSeq,
    required Future<void> Function(List<AppImMessage> messages) consumer,
  });

  Future<AppImMessage> sendText({
    required int conversationType,
    required String text,
    String? conversationId,
    int? toOrganization,
    String? toUserId,
  });

  Future<AppImMessage> sendAsset({
    required int conversationType,
    required int messageType,
    required String fileId,
    String? conversationId,
    int? toOrganization,
    String? toUserId,
  });

  Future<AppImReceipt> acknowledge({
    required AppImMessage message,
    required AppImDeliveryStatus status,
    required AppImConversationIdentityContext identity,
  });

  Future<AppImConversationReadState> markConversationRead({
    required AppImConversationIdentityContext identity,
    required AppImMessage lastReadMessage,
  });

  Future<AppImConversationSyncPage> syncConversation({
    required AppImConversationIdentityContext identity,
    required int afterMessageSeq,
    required int afterChangeSeq,
    int limit = 100,
  });

  Future<AppImMutationResult> recallMessage(
    AppImMessage message, {
    required AppImConversationIdentityContext identity,
  });

  Future<AppImMutationResult> editMessage(
    AppImMessage message,
    String text, {
    required AppImConversationIdentityContext identity,
  });

  Future<AppImMutationResult> deleteMessage(
    AppImMessage message, {
    required String scope,
    required AppImConversationIdentityContext identity,
  });

  Future<AppImMessage?> sendScreenshot(
    AppImConversationIdentityContext identity,
  );

  void sendTyping(AppImConversationIdentityContext identity);

  Future<void> reconnect();

  Future<void> close();
}

final class AppImConversationIdentityRegistry {
  AppImConversationIdentityRegistry({
    required this.organization,
    required String userId,
  }) : userId = userId.trim();

  final int organization;
  final String userId;
  final Map<String, AppImConversationIdentityContext> _identities = {};

  AppImConversationIdentityContext? operator [](String conversationId) =>
      _identities[conversationId.trim()];

  void registerAll(Iterable<AppImConversationIdentityContext> identities) {
    final additions = <String, AppImConversationIdentityContext>{};
    for (final identity in identities) {
      final canonical = _canonicalize(identity);
      final existing =
          additions[canonical.conversationId] ??
          _identities[canonical.conversationId];
      if (existing != null && !_sameIdentity(existing, canonical)) {
        throw const FormatException('会话 ID 已绑定不同复合身份');
      }
      additions[canonical.conversationId] = canonical;
    }
    _identities.addAll(additions);
  }

  AppImConversationIdentityContext _canonicalize(
    AppImConversationIdentityContext identity,
  ) {
    final conversationId = identity.conversationId.trim();
    final currentUserId = identity.userId.trim();
    final peerUserId = identity.peerUserId?.trim();
    if (organization <= 0 ||
        userId.isEmpty ||
        identity.organization != organization ||
        currentUserId != userId ||
        conversationId.isEmpty ||
        !const {1, 2}.contains(identity.conversationType) ||
        (identity.conversationType == 1 &&
            ((identity.peerOrganization ?? 0) <= 0 ||
                peerUserId == null ||
                peerUserId.isEmpty)) ||
        (identity.conversationType == 2 &&
            (identity.peerOrganization != null ||
                identity.peerUserId != null))) {
      throw const FormatException('会话复合身份上下文无效');
    }
    return AppImConversationIdentityContext(
      organization: organization,
      userId: userId,
      conversationId: conversationId,
      conversationType: identity.conversationType,
      peerOrganization: identity.peerOrganization,
      peerUserId: peerUserId,
    );
  }

  static bool _sameIdentity(
    AppImConversationIdentityContext left,
    AppImConversationIdentityContext right,
  ) =>
      left.organization == right.organization &&
      left.userId == right.userId &&
      left.conversationId == right.conversationId &&
      left.conversationType == right.conversationType &&
      left.peerOrganization == right.peerOrganization &&
      left.peerUserId == right.peerUserId;
}

abstract interface class AppImConnectorGateway {
  Future<AppImRuntime> connect({
    required TenantConfig tenant,
    required AppSession session,
  });
}

final class AppImConnector implements AppImConnectorGateway {
  const AppImConnector({
    required this.sessionService,
    required this.cursorStore,
    required this.socketFactory,
    this.timeout = const Duration(seconds: 12),
    this.reconnectDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ],
    this.sleep = _defaultSleep,
  });

  final AppSessionService sessionService;
  final ImSyncCursorGateway cursorStore;
  final ImSocketFactory socketFactory;
  final Duration timeout;
  final List<Duration> reconnectDelays;
  final Future<void> Function(Duration duration) sleep;

  @override
  Future<AppImRuntime> connect({
    required TenantConfig tenant,
    required AppSession session,
  }) {
    final accessSnapshots = AppImAccessSnapshotTracker('');
    final conversationIdentities = AppImConversationIdentityRegistry(
      organization: tenant.organization,
      userId: session.user.userId,
    );
    return _ReconnectingAppImRuntime.connect(
      connectionFactory: () => AppImConnection.connect(
        tenant: tenant,
        session: session,
        sessionService: sessionService,
        cursorStore: cursorStore,
        socketFactory: socketFactory,
        timeout: timeout,
        accessSnapshots: accessSnapshots,
        conversationIdentities: conversationIdentities,
      ),
      reconnectDelays: reconnectDelays,
      sleep: sleep,
      conversationIdentities: conversationIdentities,
    );
  }
}

Future<void> _defaultSleep(Duration duration) => Future<void>.delayed(duration);

final class AppImConnection implements AppImRuntime {
  AppImConnection._({
    required this.tenant,
    required this.session,
    required this.sessionService,
    required this.cursorStore,
    required this.socket,
    required this.timeout,
    required this._accessSnapshots,
    required this._conversationIdentities,
  });

  static Future<AppImConnection> connect({
    required TenantConfig tenant,
    required AppSession session,
    required AppSessionService sessionService,
    required ImSyncCursorGateway cursorStore,
    required ImSocketFactory socketFactory,
    Duration timeout = const Duration(seconds: 12),
    AppImAccessSnapshotTracker? accessSnapshots,
    AppImConversationIdentityRegistry? conversationIdentities,
  }) async {
    final identityRegistry =
        conversationIdentities ??
        AppImConversationIdentityRegistry(
          organization: tenant.organization,
          userId: session.user.userId,
        );
    if (identityRegistry.organization != tenant.organization ||
        identityRegistry.userId != session.user.userId.trim()) {
      throw const FormatException('会话复合身份注册表与 App 会话不一致');
    }
    final socket = await socketFactory(
      tenant.routing.primary.endpoints.imServerUri,
    ).timeout(timeout);
    final connection = AppImConnection._(
      tenant: tenant,
      session: session,
      sessionService: sessionService,
      cursorStore: cursorStore,
      socket: socket,
      timeout: timeout,
      accessSnapshots: accessSnapshots ?? AppImAccessSnapshotTracker(''),
      conversationIdentities: identityRegistry,
    );
    connection._subscription = socket.stream.listen(
      connection._handleRaw,
      onError: connection._handleSocketError,
      onDone: connection._handleSocketDone,
      cancelOnError: false,
    );
    try {
      connection._bootstrap = await connection._authenticateAndSync();
      connection._authenticated = true;
      connection._heartbeat = Timer.periodic(
        const Duration(seconds: 25),
        (_) => connection._send({'cmd': 'ping', 'data': <String, Object?>{}}),
      );
      return connection;
    } on Object {
      await connection.close();
      rethrow;
    }
  }

  final TenantConfig tenant;
  final AppSession session;
  final AppSessionService sessionService;
  final ImSyncCursorGateway cursorStore;
  final ImSocket socket;
  final Duration timeout;
  final StreamController<AppImEvent> _events =
      StreamController<AppImEvent>.broadcast(sync: true);
  final List<_PacketWaiter> _waiters = [];
  final Map<String, Future<AppImReceipt>> _pendingReceipts = {};
  final Map<String, Future<AppImMessage?>> _pendingScreenshots = {};
  final List<Map<String, Object?>> _pendingPackets = [];
  final LinkedHashSet<String> _seenEventIds = LinkedHashSet();
  final LinkedHashMap<String, AppImConversationAccessChanged>
  _recentAccessChanges = LinkedHashMap();
  final AppImConversationIdentityRegistry _conversationIdentities;
  final AppImAccessSnapshotTracker _accessSnapshots;
  Future<void> _accessEventQueue = Future<void>.value();
  _GlobalSyncResult? _pendingGlobalSync;
  Future<bool>? _globalSyncConsumeTask;
  int _accessSnapshotGeneration = 0;
  int _connectionGeneration = 0;
  StreamSubscription<Object?>? _subscription;
  Timer? _heartbeat;
  late AppImBootstrapSnapshot _bootstrap;
  bool _authenticated = false;
  bool _closed = false;

  @override
  AppImBootstrapSnapshot get bootstrap => _bootstrap;

  @override
  List<AppImConversationAccessChanged> get recentAccessChanges =>
      List.unmodifiable(_recentAccessChanges.values);

  @override
  Stream<AppImEvent> get events => _events.stream;

  @override
  bool get isConnected => _authenticated && !_closed;

  @override
  AppImConnectionStatus get connectionStatus => isConnected
      ? AppImConnectionStatus.connected
      : (_closed
            ? AppImConnectionStatus.closed
            : AppImConnectionStatus.connecting);

  @override
  void registerConversationIdentities(
    Iterable<AppImConversationIdentityContext> identities,
  ) {
    _conversationIdentities.registerAll(identities);
  }

  Future<AppImBootstrapSnapshot> _authenticateAndSync() async {
    await _restorePersistedAccessHighWater();
    final challenge = await _waitFor({'auth'});
    final clientId = _requiredString(
      imMap(challenge['data'], 'auth.data'),
      'client_id',
      'auth.client_id',
    );
    final credential = await sessionService.issueImChallenge(
      tenant: tenant,
      session: session,
      clientId: clientId,
    );
    final authWaiter = _waitFor({'auth_ack', 'error'});
    _send({
      'cmd': 'auth',
      'traceparent': TraceContext.root().traceparent,
      'data': {
        'token': credential.token,
        'device_id': session.deviceId,
        'client_family': 'app',
        'os': session.runtime.os,
      },
    });
    final authAck = await authWaiter;
    _throwIfError(authAck);
    final authData = imMap(authAck['data'], 'auth_ack.data');
    if (authAck['organization'] != tenant.organization ||
        authData['ok'] != true ||
        authData['user_id'] != session.user.userId ||
        authData['device_id'] != session.deviceId ||
        authData['client_id'] != clientId ||
        authData['credential_session_id'] != credential.credentialSessionId ||
        authData['client_family'] != 'app' ||
        authData['os'] != session.runtime.os) {
      throw const AppImConnectionException('AUTH_ACK 与 App 会话不一致');
    }
    final connectionSessionId = _requiredString(
      authData,
      'session_id',
      'auth_ack.session_id',
    );
    final authAccessSnapshotId = normalizeAppImAccessSnapshotId(
      authData['cross_org_access_snapshot_id'],
    );
    if (authAccessSnapshotId.isEmpty) {
      throw const AppImConnectionException(
        'AUTH_ACK cross_org_access_snapshot_id 无效',
        code: 'IM_ACCESS_SNAPSHOT_INVALID',
      );
    }
    final authSnapshotObservation = _accessSnapshots.reset(
      authAccessSnapshotId,
    );
    if (authSnapshotObservation == AppImAccessSnapshotObservation.invalid) {
      throw const AppImConnectionException(
        'AUTH_ACK cross_org_access_snapshot_id 无效',
        code: 'IM_ACCESS_SNAPSHOT_INVALID',
      );
    }
    if (authSnapshotObservation == AppImAccessSnapshotObservation.stale) {
      _accessSnapshots.reset('0');
    } else if (authAccessSnapshotId != '0') {
      await _persistAccessHighWater(_accessSnapshots.highestPositiveSnapshotId);
    }
    final sync = await _syncGlobal();
    _pendingGlobalSync = sync;
    final syncedMessages = _canConsumeGlobalSync(sync)
        ? sync.messages
        : const <AppImMessage>[];
    return AppImBootstrapSnapshot(
      clientId: clientId,
      connectionSessionId: connectionSessionId,
      credentialSessionId: credential.credentialSessionId,
      crossOrgAccessSnapshotId: sync.crossOrgAccessSnapshotId,
      highestCrossOrgAccessSnapshotId:
          _accessSnapshots.highestPositiveSnapshotId.isEmpty
          ? '0'
          : _accessSnapshots.highestPositiveSnapshotId,
      previousGlobalSeq: sync.previousCursor,
      nextGlobalSeq: sync.nextCursor,
      syncedMessages: List.unmodifiable(syncedMessages),
    );
  }

  Future<void> _restorePersistedAccessHighWater() async {
    final persisted = await cursorStore.readAccessSnapshotHighWater(
      tenant.organization,
      session.user.userId,
    );
    final normalized = normalizeAppImAccessSnapshotId(persisted);
    if (normalized.isEmpty) {
      throw const AppImConnectionException(
        '本地跨机构访问快照高水位无效',
        code: 'IM_ACCESS_SNAPSHOT_INVALID',
      );
    }
    if (normalized != '0') _accessSnapshots.observe(normalized);
  }

  Future<bool> _persistAccessHighWater(
    String snapshotId, {
    bool Function()? isCurrent,
  }) async {
    if (snapshotId.isEmpty || snapshotId == '0') {
      return isCurrent?.call() != false;
    }
    return cursorStore.writeAccessSnapshotHighWater(
      tenant.organization,
      session.user.userId,
      snapshotId,
      isCurrent: isCurrent,
    );
  }

  Future<_GlobalSyncResult> _syncGlobal() async {
    final previous = await cursorStore.read(
      tenant.organization,
      session.user.userId,
    );
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(previous)) {
      throw const AppImConnectionException('本地 SYNC global_seq 游标无效');
    }
    for (var attempt = 0; attempt < 5; attempt++) {
      var cursor = previous;
      String? batchSnapshotId;
      final batchAccessGeneration = _accessSnapshotGeneration;
      final batchConnectionGeneration = _connectionGeneration;
      final messages = <AppImMessage>[];
      final messageIds = <String>{};
      var restart = false;
      for (var page = 0; page < 100; page++) {
        final requestId = _clientMessageId();
        final waiter = _waitFor(
          {'sync_ack', 'error'},
          matcher: (packet) {
            if (packet['client_msg_id'] != requestId) return false;
            if (packet['cmd'] == 'error') return true;
            final data = packet['data'];
            return data is Map && data['scope'] == 'global';
          },
        );
        _send({
          'cmd': 'sync',
          'client_msg_id': requestId,
          'traceparent': TraceContext.root().traceparent,
          'data': {'after_global_seq': cursor, 'limit': 100},
        });
        final packet = await waiter;
        _throwIfError(packet);
        final data = imMap(packet['data'], 'sync_ack.data');
        if (packet['organization'] != tenant.organization ||
            data['scope'] != 'global' ||
            data['messages'] is! List ||
            data['has_more'] is! bool) {
          throw const AppImConnectionException('全局 SYNC_ACK 格式无效');
        }
        final pageAccessSnapshotId = normalizeAppImAccessSnapshotId(
          data['cross_org_access_snapshot_id'],
        );
        if (pageAccessSnapshotId.isEmpty) {
          throw const AppImConnectionException(
            'SYNC_ACK cross_org_access_snapshot_id 无效',
            code: 'IM_ACCESS_SNAPSHOT_INVALID',
          );
        }
        batchSnapshotId ??= pageAccessSnapshotId;
        if (pageAccessSnapshotId != batchSnapshotId) {
          restart = true;
          break;
        }
        final pageMessages = (data['messages'] as List)
            .map(AppImMessage.fromRealtime)
            .toList(growable: false);
        var previousMessageGlobalSeq = BigInt.parse(cursor);
        for (final message in pageMessages) {
          final messageGlobalSeq = BigInt.parse(message.globalSeq!);
          if (message.organization != tenant.organization) {
            throw const AppImConnectionException('SYNC 消息 organization 不一致');
          }
          if (messageGlobalSeq <= previousMessageGlobalSeq) {
            throw const AppImConnectionException('SYNC 消息 global_seq 未严格递增');
          }
          previousMessageGlobalSeq = messageGlobalSeq;
          final systemActorOrganization = message.messageType == 5
              ? (message.content ??
                    const <String, Object?>{})['actor_organization']
              : null;
          if (message.conversationType == 2 &&
              (message.senderOrganization != tenant.organization ||
                  (systemActorOrganization is int &&
                      systemActorOrganization != tenant.organization))) {
            throw const AppImConnectionException('群聊 SYNC 消息禁止跨机构发送者');
          }
          if (messageIds.add(message.messageId)) messages.add(message);
        }
        final next = _requiredString(
          data,
          'next_after_global_seq',
          'sync_ack.next_after_global_seq',
        );
        if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(next)) {
          throw const AppImConnectionException('SYNC global_seq 游标无效');
        }
        final nextNumber = BigInt.parse(next);
        final cursorNumber = BigInt.parse(cursor);
        if (nextNumber < cursorNumber ||
            previousMessageGlobalSeq > nextNumber) {
          throw const AppImConnectionException('SYNC global_seq 游标倒退');
        }
        final hasMore = data['has_more'] as bool;
        if (hasMore && nextNumber == cursorNumber) {
          throw const AppImConnectionException('SYNC 分页游标未前进');
        }
        cursor = next;
        if (!hasMore) {
          if (batchAccessGeneration != _accessSnapshotGeneration) {
            restart = true;
            break;
          }
          final snapshotObservation = batchSnapshotId == '0'
              ? _accessSnapshots.reset('0')
              : _accessSnapshots.observe(batchSnapshotId);
          if (snapshotObservation == AppImAccessSnapshotObservation.invalid) {
            throw const AppImConnectionException(
              'SYNC_ACK cross_org_access_snapshot_id 无效',
              code: 'IM_ACCESS_SNAPSHOT_INVALID',
            );
          }
          if (snapshotObservation == AppImAccessSnapshotObservation.stale) {
            _accessSnapshots.reset('0');
          }
          return _GlobalSyncResult(
            previous,
            cursor,
            messages,
            _accessSnapshots.latestSnapshotId,
            _accessSnapshots.highestPositiveSnapshotId,
            batchConnectionGeneration,
            batchAccessGeneration,
          );
        }
      }
      if (!restart) {
        throw const AppImConnectionException('SYNC 分页超过安全上限');
      }
    }
    throw const AppImConnectionException(
      'SYNC 期间 cross_org_access_snapshot_id 持续变化',
      code: 'IM_ACCESS_SNAPSHOT_UNSTABLE',
    );
  }

  @override
  Future<bool> consumeGlobalSync({
    required String nextGlobalSeq,
    required Future<void> Function(List<AppImMessage> messages) consumer,
  }) {
    final inFlight = _globalSyncConsumeTask;
    if (inFlight != null) return inFlight;
    late final Future<bool> operation;
    operation =
        _consumeGlobalSync(
          nextGlobalSeq: nextGlobalSeq,
          consumer: consumer,
        ).whenComplete(() {
          if (identical(_globalSyncConsumeTask, operation)) {
            _globalSyncConsumeTask = null;
          }
        });
    _globalSyncConsumeTask = operation;
    return operation;
  }

  Future<bool> _consumeGlobalSync({
    required String nextGlobalSeq,
    required Future<void> Function(List<AppImMessage> messages) consumer,
  }) async {
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(nextGlobalSeq)) {
      throw const FormatException('待消费 SYNC global_seq 游标无效');
    }
    var pending = _pendingGlobalSync;
    if (pending == null) {
      final committed = await cursorStore.read(
        tenant.organization,
        session.user.userId,
      );
      if (committed == nextGlobalSeq) return true;
      if (_closed || !_authenticated) return false;
      pending = await _syncGlobal();
      if (_closed || !_authenticated) return false;
      _pendingGlobalSync = pending;
      _updateBootstrapSync(pending);
    } else if (pending.nextCursor != nextGlobalSeq) {
      return false;
    }
    final activePending = pending;
    if (!_isGlobalSyncFenceCurrent(activePending)) return false;
    if (!_canConsumeGlobalSync(activePending)) return false;
    await consumer(List.unmodifiable(activePending.messages));
    if (!_isGlobalSyncFenceCurrent(activePending)) return false;
    final highWaterCommitted = await _persistAccessHighWater(
      activePending.accessSnapshotHighWater,
      isCurrent: () => _isGlobalSyncFenceCurrent(activePending),
    );
    if (!highWaterCommitted || !_isGlobalSyncFenceCurrent(activePending)) {
      return false;
    }
    final cursorCommitted = await cursorStore.write(
      tenant.organization,
      session.user.userId,
      activePending.nextCursor,
      isCurrent: () => _isGlobalSyncFenceCurrent(activePending),
    );
    if (!cursorCommitted || !_isGlobalSyncFenceCurrent(activePending)) {
      return false;
    }
    _pendingGlobalSync = null;
    return true;
  }

  void _updateBootstrapSync(_GlobalSyncResult sync) {
    final syncedMessages = _canConsumeGlobalSync(sync)
        ? sync.messages
        : const <AppImMessage>[];
    _bootstrap = AppImBootstrapSnapshot(
      clientId: _bootstrap.clientId,
      connectionSessionId: _bootstrap.connectionSessionId,
      credentialSessionId: _bootstrap.credentialSessionId,
      crossOrgAccessSnapshotId: sync.crossOrgAccessSnapshotId,
      highestCrossOrgAccessSnapshotId: sync.accessSnapshotHighWater.isEmpty
          ? '0'
          : sync.accessSnapshotHighWater,
      previousGlobalSeq: sync.previousCursor,
      nextGlobalSeq: sync.nextCursor,
      syncedMessages: List.unmodifiable(syncedMessages),
    );
  }

  bool _isGlobalSyncFenceCurrent(_GlobalSyncResult pending) {
    return !_closed &&
        _authenticated &&
        identical(_pendingGlobalSync, pending) &&
        _connectionGeneration == pending.connectionGeneration &&
        _accessSnapshotGeneration == pending.accessGeneration &&
        _accessSnapshots.latestSnapshotId == pending.crossOrgAccessSnapshotId;
  }

  bool _canConsumeGlobalSync(_GlobalSyncResult pending) {
    if (!_accessSnapshots.isCrossOrganizationFailClosed) return true;
    for (final message in pending.messages) {
      final systemActorOrganization = message.messageType == 5
          ? (message.content ?? const <String, Object?>{})['actor_organization']
          : null;
      final foreignOrganization =
          systemActorOrganization is int &&
              systemActorOrganization != tenant.organization
          ? systemActorOrganization
          : message.senderOrganization;
      if (_isFailClosedConversation(
        message.conversationId,
        conversationType: message.conversationType,
        foreignOrganization: foreignOrganization,
      )) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<AppImMessage> sendText({
    required int conversationType,
    required String text,
    String? conversationId,
    int? toOrganization,
    String? toUserId,
  }) async {
    if (!isConnected) {
      throw const AppImConnectionException('IM 连接未就绪');
    }
    final normalized = text.trim();
    if (normalized.isEmpty || normalized.length > 4000) {
      throw const FormatException('文本消息长度必须为 1..4000');
    }
    return _sendMessage(
      conversationType: conversationType,
      messageType: 1,
      content: {'text': normalized},
      conversationId: conversationId,
      toOrganization: toOrganization,
      toUserId: toUserId,
    );
  }

  @override
  Future<AppImMessage> sendAsset({
    required int conversationType,
    required int messageType,
    required String fileId,
    String? conversationId,
    int? toOrganization,
    String? toUserId,
  }) {
    final normalized = fileId.trim();
    if (!const {2, 3}.contains(messageType) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(normalized)) {
      throw const FormatException('App 附件消息类型或 file_id 无效');
    }
    return _sendMessage(
      conversationType: conversationType,
      messageType: messageType,
      content: {'file_id': normalized},
      conversationId: conversationId,
      toOrganization: toOrganization,
      toUserId: toUserId,
    );
  }

  Future<AppImMessage> _sendMessage({
    required int conversationType,
    required int messageType,
    required Map<String, Object?> content,
    String? conversationId,
    int? toOrganization,
    String? toUserId,
  }) async {
    if (!isConnected) {
      throw const AppImConnectionException('IM 连接未就绪');
    }
    final data = <String, Object?>{
      'conversation_type': conversationType,
      'message_type': messageType,
      'content': content,
    };
    if (conversationType == 1) {
      final peer = toUserId?.trim() ?? '';
      final peerOrganization = toOrganization ?? 0;
      if (peer.isEmpty || peerOrganization <= 0) {
        throw const FormatException('单聊缺少目标复合身份');
      }
      if (peerOrganization != tenant.organization &&
          _accessSnapshots.isCrossOrganizationFailClosed) {
        throw const AppImConnectionException(
          '跨机构访问快照尚未收敛',
          code: 'IM_ACCESS_SNAPSHOT_UNSTABLE',
        );
      }
      data['to_organization'] = peerOrganization;
      data['to_user_id'] = peer;
    } else if (conversationType == 2) {
      final target = conversationId?.trim() ?? '';
      if (target.isEmpty) {
        throw const FormatException('群聊缺少 conversation_id');
      }
      data['conversation_id'] = target;
    } else {
      throw const FormatException('conversation_type 只允许 1 或 2');
    }

    final clientMsgId = _clientMessageId();
    final waiter = _waitFor({
      'send_ack',
      'error',
    }, matcher: (packet) => packet['client_msg_id'] == clientMsgId);
    _send({
      'cmd': 'send',
      'client_msg_id': clientMsgId,
      'traceparent': TraceContext.root().traceparent,
      'data': data,
    });
    final packet = await waiter;
    _throwIfError(packet);
    final ack = imMap(packet['data'], 'send_ack.data');
    if (packet['organization'] != tenant.organization ||
        ack['ok'] != true ||
        ack['duplicated'] is! bool ||
        ack['organization'] != tenant.organization ||
        ack['client_msg_id'] != clientMsgId ||
        ack['message'] == null) {
      throw const AppImConnectionException('SEND_ACK 格式无效');
    }
    final message = AppImMessage.fromRealtime(
      ack['message'],
    ).copyWith(deliveryStatus: AppImDeliveryStatus.sent);
    if (message.organization != tenant.organization ||
        message.senderOrganization != tenant.organization ||
        message.senderId != session.user.userId ||
        message.clientMsgId != clientMsgId ||
        message.messageType != messageType ||
        message.conversationType != conversationType ||
        ack['conversation_id'] != message.conversationId ||
        ack['message_id'] != message.messageId ||
        ack['message_seq'] != message.messageSeq ||
        ack['global_seq'] != message.globalSeq ||
        (conversationType == 2 &&
            message.conversationId != conversationId?.trim()) ||
        !_containsExpectedContent(message.content, content)) {
      throw const AppImConnectionException('SEND_ACK 与发送请求不一致');
    }
    _conversationIdentities.registerAll([
      AppImConversationIdentityContext(
        organization: tenant.organization,
        userId: session.user.userId,
        conversationId: message.conversationId,
        conversationType: conversationType,
        peerOrganization: conversationType == 1 ? toOrganization : null,
        peerUserId: conversationType == 1 ? toUserId : null,
      ),
    ]);
    _events.add(
      AppImEvent(command: 'send_ack', message: message, eventId: null),
    );
    return message;
  }

  @override
  Future<AppImReceipt> acknowledge({
    required AppImMessage message,
    required AppImDeliveryStatus status,
    required AppImConversationIdentityContext identity,
  }) async {
    if (!isConnected) {
      throw const AppImConnectionException('IM 连接未就绪');
    }
    if (status == AppImDeliveryStatus.sent) {
      throw const FormatException('客户端 ACK 只允许 delivered 或 read');
    }
    _assertConversationIdentity(identity, message: message);
    final normalizedMessageId = message.messageId.trim();
    if (normalizedMessageId.isEmpty) {
      throw const FormatException('ACK 缺少 message_id');
    }
    final pending = _pendingReceipts[normalizedMessageId];
    if (pending != null) {
      final receipt = await pending;
      if (receipt.status.rank >= status.rank) return receipt;
    }
    final operation = _sendAcknowledgement(message, status);
    _pendingReceipts[normalizedMessageId] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_pendingReceipts[normalizedMessageId], operation)) {
        _pendingReceipts.remove(normalizedMessageId);
      }
    }
  }

  Future<AppImReceipt> _sendAcknowledgement(
    AppImMessage message,
    AppImDeliveryStatus status,
  ) async {
    final normalizedMessageId = message.messageId.trim();
    final requestId = _clientMessageId();
    final waiter = _waitFor({
      'ack_ack',
      'error',
    }, matcher: (packet) => packet['client_msg_id'] == requestId);
    _send({
      'cmd': 'ack',
      'client_msg_id': requestId,
      'traceparent': TraceContext.root().traceparent,
      'data': {'message_id': normalizedMessageId, 'status': status.name},
    });
    final packet = await waiter;
    _throwIfError(packet);
    final data = imMap(packet['data'], 'ack_ack.data');
    final receipt = AppImReceipt.fromJson(data, 'ack_ack.data');
    if (packet['organization'] != tenant.organization ||
        data['client_msg_id'] != requestId ||
        data['request_client_msg_id'] != requestId ||
        data['actor_organization'] != tenant.organization ||
        data['actor_user_id'] != session.user.userId ||
        receipt.messageId != normalizedMessageId ||
        receipt.conversationId != message.conversationId ||
        receipt.messageSeq != message.messageSeq ||
        receipt.senderOrganization != message.senderOrganization ||
        receipt.senderId != message.senderId ||
        receipt.userOrganization != tenant.organization ||
        receipt.userId != session.user.userId ||
        receipt.status.rank < status.rank) {
      throw const AppImConnectionException('ACK_ACK 与请求不一致');
    }
    return receipt;
  }

  @override
  Future<AppImConversationReadState> markConversationRead({
    required AppImConversationIdentityContext identity,
    required AppImMessage lastReadMessage,
  }) async {
    if (!isConnected) {
      throw const AppImConnectionException('IM 连接未就绪');
    }
    _assertConversationIdentity(identity, message: lastReadMessage);
    final normalizedConversationId = identity.conversationId.trim();
    final normalizedMessageId = lastReadMessage.messageId.trim();
    if (normalizedConversationId.isEmpty || normalizedMessageId.isEmpty) {
      throw const FormatException('会话已读缺少 conversation_id 或 message_id');
    }
    if (lastReadMessage.conversationId != normalizedConversationId) {
      throw const FormatException('最后已读消息不属于目标会话');
    }
    final requestId = _clientMessageId();
    final waiter = _waitFor({
      'conversation_read_ack',
      'error',
    }, matcher: (packet) => packet['client_msg_id'] == requestId);
    _send({
      'cmd': 'conversation_read',
      'client_msg_id': requestId,
      'traceparent': TraceContext.root().traceparent,
      'data': {
        'conversation_id': normalizedConversationId,
        'last_read_message_id': normalizedMessageId,
      },
    });
    final packet = await waiter;
    _throwIfError(packet);
    final state = AppImConversationReadState.fromJson(
      packet['data'],
      'conversation_read_ack.data',
    );
    if (packet['organization'] != tenant.organization ||
        state.conversationId != normalizedConversationId ||
        state.lastReadMessageId != normalizedMessageId ||
        state.lastReadSeq != lastReadMessage.messageSeq ||
        state.userOrganization != tenant.organization ||
        state.userId != session.user.userId) {
      throw const AppImConnectionException('CONVERSATION_READ_ACK 与请求不一致');
    }
    return state;
  }

  @override
  Future<AppImConversationSyncPage> syncConversation({
    required AppImConversationIdentityContext identity,
    required int afterMessageSeq,
    required int afterChangeSeq,
    int limit = 100,
  }) async {
    if (!isConnected) {
      throw const AppImConnectionException('IM 连接未就绪');
    }
    _assertConversationIdentity(identity);
    final normalizedConversationId = identity.conversationId.trim();
    if (normalizedConversationId.isEmpty ||
        afterMessageSeq < 0 ||
        afterChangeSeq < 0 ||
        limit < 1 ||
        limit > 100) {
      throw const FormatException('会话 SYNC 参数无效');
    }
    final requestId = _clientMessageId();
    final waiter = _waitFor(
      {'sync_ack', 'error'},
      matcher: (packet) {
        if (packet['client_msg_id'] != requestId) return false;
        if (packet['cmd'] == 'error') return true;
        final data = packet['data'];
        return data is Map &&
            data['scope'] == 'conversation' &&
            data['conversation_id'] == normalizedConversationId;
      },
    );
    _send({
      'cmd': 'sync',
      'client_msg_id': requestId,
      'traceparent': TraceContext.root().traceparent,
      'data': {
        'conversation_id': normalizedConversationId,
        'after_seq': afterMessageSeq,
        'after_change_seq': afterChangeSeq,
        'limit': limit,
      },
    });
    final packet = await waiter;
    _throwIfError(packet);
    if (packet['organization'] != tenant.organization) {
      throw const AppImConnectionException('会话 SYNC_ACK organization 不一致');
    }
    final page = AppImConversationSyncPage.fromJson(
      packet['data'],
      identity: identity,
    );
    if (page.nextAfterMessageSeq < afterMessageSeq ||
        page.nextAfterChangeSeq < afterChangeSeq ||
        (page.messagesHasMore && page.nextAfterMessageSeq == afterMessageSeq) ||
        (page.changesHasMore && page.nextAfterChangeSeq == afterChangeSeq)) {
      throw const AppImConnectionException('会话 SYNC_ACK 游标未前进');
    }
    var previousMessageSeq = afterMessageSeq;
    for (final message in page.messages) {
      if (message.organization != tenant.organization ||
          message.conversationId != normalizedConversationId ||
          message.messageSeq <= previousMessageSeq ||
          message.messageSeq > page.nextAfterMessageSeq) {
        throw const AppImConnectionException('会话 SYNC_ACK 消息序列无效');
      }
      previousMessageSeq = message.messageSeq;
    }
    var previousChangeSeq = afterChangeSeq;
    for (final change in page.changes) {
      if (change.changeSeq <= previousChangeSeq ||
          change.changeSeq > page.nextAfterChangeSeq) {
        throw const AppImConnectionException('会话 SYNC_ACK 变更序列无效');
      }
      previousChangeSeq = change.changeSeq;
    }
    return page;
  }

  @override
  Future<AppImMutationResult> recallMessage(
    AppImMessage message, {
    required AppImConversationIdentityContext identity,
  }) async {
    _assertConversationIdentity(identity, message: message);
    _assertOwnMutableMessage(message, requireText: false);
    final packet = await _sendMutationRequest(
      command: 'recall',
      ackCommand: 'recall_ack',
      message: message,
      data: {'message_id': message.messageId},
    );
    final data = imMap(packet['data'], 'recall_ack.data');
    if (data['recalled'] != true || !_isPositiveInt(data['change_seq'])) {
      throw const AppImConnectionException('RECALL_ACK 状态无效');
    }
    return AppImMutationResult(
      command: 'recall',
      conversationId: message.conversationId,
      messageId: message.messageId,
      messageSeq: message.messageSeq,
      changeSeq: data['change_seq'] as int,
      scope: '',
      status: 'recalled',
      message: null,
    );
  }

  @override
  Future<AppImMutationResult> editMessage(
    AppImMessage message,
    String text, {
    required AppImConversationIdentityContext identity,
  }) async {
    _assertConversationIdentity(identity, message: message);
    _assertOwnMutableMessage(message, requireText: true);
    final normalized = text.trim();
    if (normalized.isEmpty || normalized.length > 4000) {
      throw const FormatException('编辑文本长度必须为 1..4000');
    }
    final packet = await _sendMutationRequest(
      command: 'edit',
      ackCommand: 'edit_ack',
      message: message,
      data: {
        'message_id': message.messageId,
        'content': {'text': normalized},
      },
    );
    final data = imMap(packet['data'], 'edit_ack.data');
    if (!_isPositiveInt(data['change_seq']) ||
        !_deepEqual(data['content'], {'text': normalized})) {
      throw const AppImConnectionException('EDIT_ACK 内容或变更序号无效');
    }
    final edited = AppImMessage.fromRealtime(data['message']);
    if (edited.organization != tenant.organization ||
        edited.conversationId != message.conversationId ||
        edited.messageId != message.messageId ||
        edited.messageSeq != message.messageSeq ||
        edited.senderOrganization != message.senderOrganization ||
        edited.senderId != message.senderId ||
        edited.content?['text'] != normalized ||
        edited.editCount <= message.editCount) {
      throw const AppImConnectionException('EDIT_ACK 与原消息或请求不一致');
    }
    return AppImMutationResult(
      command: 'edit',
      conversationId: message.conversationId,
      messageId: message.messageId,
      messageSeq: message.messageSeq,
      changeSeq: data['change_seq'] as int,
      scope: '',
      status: '',
      message: edited,
    );
  }

  @override
  Future<AppImMutationResult> deleteMessage(
    AppImMessage message, {
    required String scope,
    required AppImConversationIdentityContext identity,
  }) async {
    _assertConversationIdentity(identity, message: message);
    final normalizedScope = scope.trim();
    if (!const {'self', 'both'}.contains(normalizedScope)) {
      throw const FormatException('删除范围只允许 self 或 both');
    }
    if (normalizedScope == 'both') {
      _assertOwnMutableMessage(message, requireText: false);
    }
    final packet = await _sendMutationRequest(
      command: 'delete',
      ackCommand: 'delete_ack',
      message: message,
      data: {'message_id': message.messageId, 'scope': normalizedScope},
    );
    final data = imMap(packet['data'], 'delete_ack.data');
    if (data['scope'] != normalizedScope ||
        !_isPositiveInt(data['change_seq'])) {
      throw const AppImConnectionException('DELETE_ACK 与请求范围不一致');
    }
    return AppImMutationResult(
      command: 'delete',
      conversationId: message.conversationId,
      messageId: message.messageId,
      messageSeq: message.messageSeq,
      changeSeq: data['change_seq'] as int,
      scope: normalizedScope,
      status: normalizedScope == 'both' ? 'deleted_both' : '',
      message: null,
    );
  }

  @override
  Future<AppImMessage?> sendScreenshot(
    AppImConversationIdentityContext identity,
  ) {
    _assertConversationIdentity(identity);
    final normalized = identity.conversationId.trim();
    if (normalized.isEmpty) {
      throw const FormatException('截屏提示缺少 conversation_id');
    }
    final pending = _pendingScreenshots[normalized];
    if (pending != null) return pending;
    late final Future<AppImMessage?> operation;
    operation = _sendScreenshotRequest(normalized).whenComplete(() {
      if (identical(_pendingScreenshots[normalized], operation)) {
        _pendingScreenshots.remove(normalized);
      }
    });
    _pendingScreenshots[normalized] = operation;
    return operation;
  }

  Future<AppImMessage?> _sendScreenshotRequest(String conversationId) async {
    if (!isConnected) {
      throw const AppImConnectionException('IM 连接未就绪');
    }
    final requestId = _clientMessageId();
    final waiter = _waitFor({
      'screenshot_ack',
      'error',
    }, matcher: (packet) => packet['client_msg_id'] == requestId);
    _send({
      'cmd': 'screenshot',
      'client_msg_id': requestId,
      'traceparent': TraceContext.root().traceparent,
      'data': {'conversation_id': conversationId},
    });
    final packet = await waiter;
    _throwIfError(packet);
    final data = imMap(packet['data'], 'screenshot_ack.data');
    if (packet['organization'] != tenant.organization ||
        data['client_msg_id'] != requestId ||
        data['request_client_msg_id'] != requestId ||
        data['actor_organization'] != tenant.organization ||
        data['actor_user_id'] != session.user.userId ||
        data['conversation_id'] != conversationId ||
        data['enabled'] is! bool) {
      throw const AppImConnectionException('SCREENSHOT_ACK 格式无效');
    }
    final enabled = data['enabled'] as bool;
    final noticeValue = data['notice_message'];
    if (enabled != (noticeValue != null)) {
      throw const AppImConnectionException('SCREENSHOT_ACK 提示状态不一致');
    }
    if (!enabled) return null;
    final notice = AppImMessage.fromRealtime(noticeValue);
    if (notice.organization != tenant.organization ||
        notice.conversationId != conversationId ||
        notice.messageType != 5 ||
        notice.senderOrganization != tenant.organization ||
        notice.content?['actor_organization'] != tenant.organization ||
        notice.content?['actor_user_id'] != session.user.userId) {
      throw const AppImConnectionException('SCREENSHOT_ACK 系统提示无效');
    }
    return notice;
  }

  @override
  void sendTyping(AppImConversationIdentityContext identity) {
    _assertConversationIdentity(identity);
    final normalized = identity.conversationId.trim();
    if (!isConnected) {
      throw const AppImConnectionException('IM 连接未就绪');
    }
    if (normalized.isEmpty) {
      throw const FormatException('正在输入缺少 conversation_id');
    }
    _send({
      'cmd': 'typing',
      'traceparent': TraceContext.root().traceparent,
      'data': {'conversation_id': normalized},
    });
  }

  Future<Map<String, Object?>> _sendMutationRequest({
    required String command,
    required String ackCommand,
    required AppImMessage message,
    required Map<String, Object?> data,
  }) async {
    if (!isConnected) {
      throw const AppImConnectionException('IM 连接未就绪');
    }
    final requestId = _clientMessageId();
    final waiter = _waitFor({
      ackCommand,
      'error',
    }, matcher: (packet) => packet['client_msg_id'] == requestId);
    _send({
      'cmd': command,
      'client_msg_id': requestId,
      'traceparent': TraceContext.root().traceparent,
      'data': data,
    });
    final packet = await waiter;
    _throwIfError(packet);
    final response = imMap(packet['data'], '$ackCommand.data');
    if (packet['organization'] != tenant.organization ||
        response['client_msg_id'] != requestId ||
        response['request_client_msg_id'] != requestId ||
        response['actor_organization'] != tenant.organization ||
        response['actor_user_id'] != session.user.userId ||
        response['message_id'] != message.messageId ||
        response['conversation_id'] != message.conversationId) {
      throw AppImConnectionException('${ackCommand.toUpperCase()} 与原消息不一致');
    }
    return packet;
  }

  void _assertConversationIdentity(
    AppImConversationIdentityContext identity, {
    AppImMessage? message,
  }) {
    if (message != null && !identity.acceptsMessage(message)) {
      throw const FormatException('会话复合身份上下文无效');
    }
    _conversationIdentities.registerAll([identity]);
    final registered = _conversationIdentities[identity.conversationId];
    if (registered == null ||
        (message != null && !registered.acceptsMessage(message))) {
      throw const FormatException('会话复合身份上下文无效');
    }
    if (registered.isCrossOrganization &&
        _accessSnapshots.isCrossOrganizationFailClosed) {
      throw const AppImConnectionException(
        '跨机构访问快照尚未收敛',
        code: 'IM_ACCESS_SNAPSHOT_UNSTABLE',
      );
    }
  }

  bool _isFailClosedConversation(
    String conversationId, {
    int? conversationType,
    int? foreignOrganization,
  }) {
    final identity = _conversationIdentities[conversationId];
    if ((conversationType == 2 || identity?.conversationType == 2) &&
        foreignOrganization != null &&
        foreignOrganization != tenant.organization) {
      return true;
    }
    if (!_accessSnapshots.isCrossOrganizationFailClosed) return false;
    if (foreignOrganization != null &&
        foreignOrganization != tenant.organization) {
      return true;
    }
    if (identity != null) {
      return identity.conversationType == 1 && identity.isCrossOrganization;
    }
    return conversationType != 2;
  }

  void _assertOwnMutableMessage(
    AppImMessage message, {
    required bool requireText,
  }) {
    if (message.organization != tenant.organization ||
        message.senderOrganization != tenant.organization ||
        message.senderId != session.user.userId ||
        message.status != 'normal' ||
        (requireText && message.messageType != 1)) {
      throw const FormatException('只能变更当前复合身份发送的有效消息');
    }
  }

  @override
  Future<void> reconnect() async {
    throw const AppImConnectionException('底层 IM 连接不支持直接重连');
  }

  void _handleRaw(Object? raw) {
    if (_closed || raw is! String) return;
    try {
      final packet = imMap(jsonDecode(raw), 'IM packet');
      final command = packet['cmd'];
      if (command is! String || command.trim().isEmpty) {
        throw const FormatException('IM packet.cmd 无效');
      }
      final packetOrganization = packet['organization'];
      final isUnscopedPreAuthPacket =
          !_authenticated &&
          packetOrganization == 0 &&
          (command == 'auth' || command == 'error');
      if (packetOrganization != tenant.organization &&
          !isUnscopedPreAuthPacket) {
        throw const FormatException('IM packet.organization 不一致');
      }
      for (final waiter in List<_PacketWaiter>.from(_waiters)) {
        if (waiter.matches(packet)) {
          _waiters.remove(waiter);
          waiter.completer.complete(packet);
          return;
        }
      }
      if (command == 'pong') return;
      if (command == 'push') {
        _handlePush(packet);
        return;
      }
      if (command == 'ack') {
        final data = imMap(packet['data'], 'ack.data');
        final receipt = AppImReceipt.fromJson(data, 'ack.data');
        final foreignOrganization =
            receipt.senderOrganization != tenant.organization
            ? receipt.senderOrganization
            : receipt.userOrganization;
        if (_isFailClosedConversation(
          receipt.conversationId,
          foreignOrganization: foreignOrganization,
        )) {
          return;
        }
        final eventId = _observeEvent(data, 'message.receipt');
        if (eventId == null) return;
        _events.add(
          AppImEvent(
            command: command,
            message: null,
            eventId: eventId,
            receipt: receipt,
          ),
        );
        return;
      }
      if (command == 'conversation_read') {
        final data = imMap(packet['data'], 'conversation_read.data');
        final read = AppImConversationReadState.fromJson(
          data,
          'conversation_read.data',
        );
        if (_isFailClosedConversation(
          read.conversationId,
          foreignOrganization: read.userOrganization,
        )) {
          return;
        }
        final eventId = _observeEvent(data, 'conversation.read');
        if (eventId == null) return;
        _events.add(
          AppImEvent(
            command: command,
            message: null,
            eventId: eventId,
            conversationRead: read,
          ),
        );
        return;
      }
      if (const {'recall', 'edit', 'delete'}.contains(command)) {
        final mutation = AppImMessageMutation.fromJson(
          command,
          packet['data'],
          tenant.organization,
        );
        final foreignOrganization =
            mutation.actorOrganization != tenant.organization
            ? mutation.actorOrganization
            : mutation.targetOrganization;
        if (_isFailClosedConversation(
          mutation.conversationId,
          foreignOrganization: foreignOrganization,
        )) {
          return;
        }
        if (!_seenEventIds.add(mutation.eventId)) return;
        _trimSeenEvents();
        _events.add(
          AppImEvent(
            command: command,
            message: null,
            eventId: mutation.eventId,
            mutation: mutation,
          ),
        );
        return;
      }
      if (command == 'typing') {
        final typing = AppImTypingState.fromJson(packet['data']);
        if (_isFailClosedConversation(
          typing.conversationId,
          foreignOrganization: typing.actorOrganization,
        )) {
          return;
        }
        _events.add(
          AppImEvent(
            command: command,
            message: null,
            eventId: null,
            typing: typing,
          ),
        );
        return;
      }
      if (command == 'conversation.access_changed') {
        final accessChanged = AppImConversationAccessChanged.fromJson(
          packet['data'],
          expectedOrganization: tenant.organization,
          expectedUserId: session.user.userId,
        );
        if (!_seenEventIds.add(accessChanged.eventId)) return;
        _trimSeenEvents();
        final snapshotObservation = _accessSnapshots.observe(
          accessChanged.snapshotId,
        );
        if (snapshotObservation == AppImAccessSnapshotObservation.invalid) {
          throw const FormatException('conversation.access_changed 访问快照无效');
        }
        if (snapshotObservation == AppImAccessSnapshotObservation.stale) {
          return;
        }
        _accessSnapshotGeneration += 1;
        _pendingGlobalSync = null;
        _queueAccessChanged(
          accessChanged,
          persistHighWater:
              snapshotObservation == AppImAccessSnapshotObservation.fresh,
        );
        return;
      }
      if (command == 'error') {
        _events.addError(_errorFromPacket(packet));
        return;
      }
      _pendingPackets.add(packet);
      if (_pendingPackets.length > 32) _pendingPackets.removeAt(0);
    } on Object catch (error, stackTrace) {
      _events.addError(error, stackTrace);
      unawaited(close());
    }
  }

  void _queueAccessChanged(
    AppImConversationAccessChanged accessChanged, {
    required bool persistHighWater,
  }) {
    final operation = _accessEventQueue.then((_) async {
      if (persistHighWater) {
        await _persistAccessHighWater(accessChanged.snapshotId);
      }
      if (_closed) return;
      _recentAccessChanges[accessChanged.eventId] = accessChanged;
      if (_recentAccessChanges.length > 256) {
        _recentAccessChanges.remove(_recentAccessChanges.keys.first);
      }
      _events.add(
        AppImEvent(
          command: 'conversation.access_changed',
          message: null,
          eventId: accessChanged.eventId,
          accessChanged: accessChanged,
        ),
      );
    });
    _accessEventQueue = operation.then<void>((_) {}, onError: (_, _) {});
    unawaited(
      operation.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (!_events.isClosed) _events.addError(error, stackTrace);
          unawaited(close());
        },
      ),
    );
  }

  void _handlePush(Map<String, Object?> packet) {
    final data = imMap(packet['data'], 'push.data');
    final eventId = _observeEvent(data, 'message.created');
    if (eventId == null) return;
    final message = AppImMessage.fromRealtime(data['message']);
    if (message.organization != tenant.organization ||
        data['message_id'] != message.messageId ||
        data['conversation_id'] != message.conversationId ||
        data['message_seq'] != message.messageSeq ||
        (message.conversationType == 2 &&
            message.senderOrganization != tenant.organization) ||
        (message.messageType == 5 &&
            (message.senderOrganization != tenant.organization ||
                message.content?['actor_organization'] is! int ||
                message.content?['actor_user_id'] is! String))) {
      throw const FormatException('push message organization 不一致');
    }
    final systemActorOrganization = message.messageType == 5
        ? (message.content ?? const <String, Object?>{})['actor_organization']
        : null;
    if (_isFailClosedConversation(
      message.conversationId,
      conversationType: message.conversationType,
      foreignOrganization:
          systemActorOrganization is int &&
              systemActorOrganization != tenant.organization
          ? systemActorOrganization
          : message.senderOrganization,
    )) {
      return;
    }
    _events.add(
      AppImEvent(command: 'push', message: message, eventId: eventId),
    );
  }

  String? _observeEvent(Map<String, Object?> data, String expectedEventType) {
    final eventId = _requiredString(
      data,
      'event_id',
      '$expectedEventType.event_id',
    );
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(eventId) ||
        data['event_type'] != expectedEventType) {
      throw FormatException('$expectedEventType 事件协议无效');
    }
    if (!_seenEventIds.add(eventId)) return null;
    _trimSeenEvents();
    return eventId;
  }

  void _trimSeenEvents() {
    if (_seenEventIds.length > 2048) _seenEventIds.remove(_seenEventIds.first);
  }

  Future<Map<String, Object?>> _waitFor(
    Set<String> commands, {
    bool Function(Map<String, Object?> packet)? matcher,
  }) {
    bool matches(Map<String, Object?> packet) {
      final command = packet['cmd'];
      return command is String &&
          commands.contains(command) &&
          (matcher == null || matcher(packet));
    }

    final queuedIndex = _pendingPackets.indexWhere(matches);
    if (queuedIndex >= 0) {
      return Future.value(_pendingPackets.removeAt(queuedIndex));
    }
    final completer = Completer<Map<String, Object?>>();
    late final _PacketWaiter waiter;
    waiter = _PacketWaiter(commands, matcher, completer);
    _waiters.add(waiter);
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw AppImConnectionException('等待 ${commands.join('/')} 超时');
      },
    );
  }

  void _send(Map<String, Object?> packet) {
    if (_closed) throw const AppImConnectionException('IM 连接已关闭');
    socket.send(
      jsonEncode({
        ...packet,
        'organization': tenant.organization,
        'ts': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  void _throwIfError(Map<String, Object?> packet) {
    if (packet['cmd'] == 'error') throw _errorFromPacket(packet);
  }

  AppImConnectionException _errorFromPacket(Map<String, Object?> packet) {
    final data = imMap(packet['data'], 'error.data');
    final code = data['code'] is String ? data['code'] as String : 'IM_ERROR';
    final rawMessage = data['message'] ?? data['msg'];
    final message = rawMessage is String && rawMessage.trim().isNotEmpty
        ? rawMessage.trim()
        : 'IM 请求失败';
    return AppImConnectionException('$code: $message', code: code);
  }

  void _handleSocketError(Object error, StackTrace stackTrace) {
    if (_closed) return;
    _events.addError(
      AppImConnectionException('IM 连接异常: ${error.runtimeType}'),
      stackTrace,
    );
    unawaited(close());
  }

  void _handleSocketDone() {
    if (!_closed) unawaited(close());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _authenticated = false;
    _connectionGeneration += 1;
    _pendingGlobalSync = null;
    _heartbeat?.cancel();
    final exception = const AppImConnectionException('IM 连接已关闭');
    for (final waiter in List<_PacketWaiter>.from(_waiters)) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(exception);
      }
    }
    _waiters.clear();
    await _accessEventQueue;
    await _subscription?.cancel();
    await socket.close();
    await _events.close();
  }

  static String _requiredString(
    Map<String, Object?> map,
    String key,
    String field,
  ) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$field 格式无效');
    }
    return value.trim();
  }

  static bool _isPositiveInt(Object? value) => value is int && value > 0;

  static bool _deepEqual(Object? left, Object? right) {
    if (identical(left, right) || left == right) return true;
    if (left is List && right is List) {
      return left.length == right.length &&
          List.generate(
            left.length,
            (index) => _deepEqual(left[index], right[index]),
          ).every((matches) => matches);
    }
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final entry in left.entries) {
        if (!right.containsKey(entry.key) ||
            !_deepEqual(entry.value, right[entry.key])) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  static bool _containsExpectedContent(Object? actual, Object? expected) {
    if (expected is! Map) return _deepEqual(actual, expected);
    if (actual is! Map) return false;
    for (final entry in expected.entries) {
      if (!actual.containsKey(entry.key) ||
          !_containsExpectedContent(actual[entry.key], entry.value)) {
        return false;
      }
    }
    return true;
  }

  static String _clientMessageId() {
    final random = Random.secure();
    const alphabet = '0123456789abcdef';
    final suffix = List.generate(
      24,
      (_) => alphabet[random.nextInt(16)],
    ).join();
    return 'app-${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }
}

final class _ReconnectingAppImRuntime implements AppImRuntime {
  _ReconnectingAppImRuntime._({
    required this._connectionFactory,
    required List<Duration> reconnectDelays,
    required this._sleep,
    required this._conversationIdentities,
  }) : _reconnectDelays = List.unmodifiable(reconnectDelays);

  static Future<_ReconnectingAppImRuntime> connect({
    required Future<AppImConnection> Function() connectionFactory,
    required List<Duration> reconnectDelays,
    required Future<void> Function(Duration duration) sleep,
    required AppImConversationIdentityRegistry conversationIdentities,
  }) async {
    if (reconnectDelays.isEmpty ||
        reconnectDelays.any((item) => item.isNegative)) {
      throw ArgumentError('重连退避配置无效');
    }
    final runtime = _ReconnectingAppImRuntime._(
      connectionFactory: connectionFactory,
      reconnectDelays: reconnectDelays,
      sleep: sleep,
      conversationIdentities: conversationIdentities,
    );
    final connection = await connectionFactory();
    if (!runtime._attach(connection, generation: runtime._generation)) {
      throw const AppImConnectionException(
        'IM 初始连接访问快照早于本地高水位',
        code: 'IM_ACCESS_SNAPSHOT_UNSTABLE',
      );
    }
    return runtime;
  }

  final Future<AppImConnection> Function() _connectionFactory;
  final List<Duration> _reconnectDelays;
  final Future<void> Function(Duration duration) _sleep;
  final AppImConversationIdentityRegistry _conversationIdentities;
  final StreamController<AppImEvent> _events =
      StreamController<AppImEvent>.broadcast(sync: true);
  final LinkedHashMap<String, AppImConversationAccessChanged>
  _recentAccessChanges = LinkedHashMap();
  final AppImAccessSnapshotTracker _accessSnapshots =
      AppImAccessSnapshotTracker('');
  AppImConnection? _active;
  StreamSubscription<AppImEvent>? _activeSubscription;
  Future<void>? _reconnectTask;
  late AppImBootstrapSnapshot _bootstrap;
  AppImConnectionStatus _status = AppImConnectionStatus.connecting;
  int _generation = 0;
  bool _closed = false;

  @override
  AppImBootstrapSnapshot get bootstrap => _bootstrap;

  @override
  List<AppImConversationAccessChanged> get recentAccessChanges =>
      List.unmodifiable(_recentAccessChanges.values);

  @override
  Stream<AppImEvent> get events => _events.stream;

  @override
  bool get isConnected => !_closed && _active?.isConnected == true;

  @override
  AppImConnectionStatus get connectionStatus => _status;

  @override
  void registerConversationIdentities(
    Iterable<AppImConversationIdentityContext> identities,
  ) {
    _conversationIdentities.registerAll(identities);
  }

  @override
  Future<bool> consumeGlobalSync({
    required String nextGlobalSeq,
    required Future<void> Function(List<AppImMessage> messages) consumer,
  }) async {
    final connection = _active;
    if (_closed || connection == null || !connection.isConnected) {
      return false;
    }
    final generation = _generation;
    final consumed = await connection.consumeGlobalSync(
      nextGlobalSeq: nextGlobalSeq,
      consumer: (messages) async {
        await Future<void>.microtask(() {});
        if (_closed ||
            _generation != generation ||
            !identical(_active, connection)) {
          throw const AppImConnectionException('SYNC 消费期间连接已变化');
        }
        for (final message in messages) {
          _events.add(
            AppImEvent(command: 'sync', message: message, eventId: null),
          );
        }
        await consumer(messages);
        if (_closed ||
            _generation != generation ||
            !identical(_active, connection)) {
          throw const AppImConnectionException('SYNC 消费期间连接已变化');
        }
      },
    );
    if (!_closed &&
        _generation == generation &&
        identical(_active, connection)) {
      _bootstrap = connection.bootstrap;
    }
    return consumed;
  }

  bool _attach(AppImConnection connection, {required int generation}) {
    if (_closed || generation != _generation) {
      unawaited(connection.close());
      return false;
    }
    final incoming = connection.bootstrap;
    final incomingHighest = incoming.highestCrossOrgAccessSnapshotId;
    if (incomingHighest != '0') {
      _accessSnapshots.observe(incomingHighest);
    }
    final incomingCurrent = incoming.crossOrgAccessSnapshotId;
    final currentObservation = incomingCurrent == '0'
        ? _accessSnapshots.reset('0')
        : _accessSnapshots.reset(incomingCurrent);
    if (currentObservation == AppImAccessSnapshotObservation.invalid) {
      unawaited(connection.close());
      return false;
    }
    if (currentObservation == AppImAccessSnapshotObservation.stale) {
      _accessSnapshots.reset('0');
    }
    _discardAccessChangesBefore(_accessSnapshots.latestSnapshotId);
    for (final accessChanged in connection.recentAccessChanges) {
      _rememberAccessChange(accessChanged);
    }
    _bootstrap = AppImBootstrapSnapshot(
      clientId: incoming.clientId,
      connectionSessionId: incoming.connectionSessionId,
      credentialSessionId: incoming.credentialSessionId,
      crossOrgAccessSnapshotId: _accessSnapshots.latestSnapshotId,
      highestCrossOrgAccessSnapshotId:
          _accessSnapshots.highestPositiveSnapshotId.isEmpty
          ? '0'
          : _accessSnapshots.highestPositiveSnapshotId,
      previousGlobalSeq: incoming.previousGlobalSeq,
      nextGlobalSeq: incoming.nextGlobalSeq,
      syncedMessages: incoming.syncedMessages,
    );
    _active = connection;
    _activeSubscription = connection.events.listen(
      (event) {
        if (event.accessChanged case final accessChanged?) {
          if (!_rememberAccessChange(accessChanged)) return;
        }
        _events.add(event);
      },
      onError: _events.addError,
      onDone: () => _handleDisconnected(connection),
    );
    _setStatus(AppImConnectionStatus.connected);
    return true;
  }

  void _discardAccessChangesBefore(String currentSnapshotId) {
    if (currentSnapshotId == '0') return;
    _recentAccessChanges.removeWhere(
      (_, accessChanged) =>
          compareAppImAccessSnapshotIds(
            accessChanged.snapshotId,
            currentSnapshotId,
          ) <
          0,
    );
  }

  void _handleDisconnected(AppImConnection connection) {
    if (_closed || !identical(_active, connection)) return;
    _active = null;
    _activeSubscription = null;
    _setStatus(AppImConnectionStatus.reconnecting);
    final generation = ++_generation;
    _startReconnectLoop(generation);
  }

  void _startReconnectLoop(int generation) {
    final future = _runReconnectLoop(generation);
    _reconnectTask = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_reconnectTask, future)) _reconnectTask = null;
      }),
    );
  }

  Future<void> _runReconnectLoop(int generation) async {
    var attempt = 0;
    while (!_closed && generation == _generation && _active == null) {
      final delay = _reconnectDelays[min(attempt, _reconnectDelays.length - 1)];
      await _sleep(delay);
      if (_closed || generation != _generation || _active != null) return;
      try {
        final connection = await _connectionFactory();
        if (_closed || generation != _generation) {
          await connection.close();
          return;
        }
        if (_attach(connection, generation: generation)) {
          return;
        }
        attempt += 1;
      } on Object catch (error, stackTrace) {
        if (!_closed && generation == _generation) {
          _events.addError(
            isAppImAccessSnapshotFailure(error)
                ? error
                : AppImConnectionException('IM 第 ${attempt + 1} 次重连失败: $error'),
            stackTrace,
          );
        }
        attempt += 1;
      }
    }
  }

  void _setStatus(AppImConnectionStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_events.isClosed) {
      _events.add(
        AppImEvent(
          command: 'connection_state',
          message: null,
          eventId: null,
          connectionStatus: status,
        ),
      );
    }
  }

  bool _rememberAccessChange(AppImConversationAccessChanged accessChanged) {
    if (_recentAccessChanges.containsKey(accessChanged.eventId)) return false;
    final observation = _accessSnapshots.observe(accessChanged.snapshotId);
    if (observation == AppImAccessSnapshotObservation.invalid ||
        observation == AppImAccessSnapshotObservation.stale) {
      return false;
    }
    _recentAccessChanges[accessChanged.eventId] = accessChanged;
    if (_recentAccessChanges.length > 256) {
      _recentAccessChanges.remove(_recentAccessChanges.keys.first);
    }
    return true;
  }

  AppImConnection _requireActive() {
    final connection = _active;
    if (_closed || connection == null || !connection.isConnected) {
      throw const AppImConnectionException('IM 正在重连，请稍后重试');
    }
    return connection;
  }

  @override
  Future<AppImMessage> sendText({
    required int conversationType,
    required String text,
    String? conversationId,
    int? toOrganization,
    String? toUserId,
  }) {
    return _requireActive().sendText(
      conversationType: conversationType,
      text: text,
      conversationId: conversationId,
      toOrganization: toOrganization,
      toUserId: toUserId,
    );
  }

  @override
  Future<AppImMessage> sendAsset({
    required int conversationType,
    required int messageType,
    required String fileId,
    String? conversationId,
    int? toOrganization,
    String? toUserId,
  }) {
    return _requireActive().sendAsset(
      conversationType: conversationType,
      messageType: messageType,
      fileId: fileId,
      conversationId: conversationId,
      toOrganization: toOrganization,
      toUserId: toUserId,
    );
  }

  @override
  Future<AppImReceipt> acknowledge({
    required AppImMessage message,
    required AppImDeliveryStatus status,
    required AppImConversationIdentityContext identity,
  }) {
    return _requireActive().acknowledge(
      message: message,
      status: status,
      identity: identity,
    );
  }

  @override
  Future<AppImConversationReadState> markConversationRead({
    required AppImConversationIdentityContext identity,
    required AppImMessage lastReadMessage,
  }) {
    return _requireActive().markConversationRead(
      identity: identity,
      lastReadMessage: lastReadMessage,
    );
  }

  @override
  Future<AppImConversationSyncPage> syncConversation({
    required AppImConversationIdentityContext identity,
    required int afterMessageSeq,
    required int afterChangeSeq,
    int limit = 100,
  }) {
    return _requireActive().syncConversation(
      identity: identity,
      afterMessageSeq: afterMessageSeq,
      afterChangeSeq: afterChangeSeq,
      limit: limit,
    );
  }

  @override
  Future<AppImMutationResult> recallMessage(
    AppImMessage message, {
    required AppImConversationIdentityContext identity,
  }) {
    return _requireActive().recallMessage(message, identity: identity);
  }

  @override
  Future<AppImMutationResult> editMessage(
    AppImMessage message,
    String text, {
    required AppImConversationIdentityContext identity,
  }) {
    return _requireActive().editMessage(message, text, identity: identity);
  }

  @override
  Future<AppImMutationResult> deleteMessage(
    AppImMessage message, {
    required String scope,
    required AppImConversationIdentityContext identity,
  }) {
    return _requireActive().deleteMessage(
      message,
      scope: scope,
      identity: identity,
    );
  }

  @override
  Future<AppImMessage?> sendScreenshot(
    AppImConversationIdentityContext identity,
  ) {
    return _requireActive().sendScreenshot(identity);
  }

  @override
  void sendTyping(AppImConversationIdentityContext identity) {
    _requireActive().sendTyping(identity);
  }

  @override
  Future<void> reconnect() async {
    if (_closed) throw const AppImConnectionException('IM 连接已关闭');
    final generation = ++_generation;
    final current = _active;
    _active = null;
    await _activeSubscription?.cancel();
    _activeSubscription = null;
    await current?.close();
    _setStatus(AppImConnectionStatus.reconnecting);
    try {
      final connection = await _connectionFactory();
      if (_closed || generation != _generation) {
        await connection.close();
        return;
      }
      if (!_attach(connection, generation: generation)) {
        throw const AppImConnectionException(
          'IM 重连访问快照早于本地高水位',
          code: 'IM_ACCESS_SNAPSHOT_UNSTABLE',
        );
      }
    } on Object {
      if (!_closed && generation == _generation) {
        _startReconnectLoop(generation);
      }
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation += 1;
    _setStatus(AppImConnectionStatus.closed);
    final current = _active;
    _active = null;
    await _activeSubscription?.cancel();
    _activeSubscription = null;
    await current?.close();
    await _events.close();
  }
}

final class _PacketWaiter {
  const _PacketWaiter(this.commands, this.matcher, this.completer);

  final Set<String> commands;
  final bool Function(Map<String, Object?> packet)? matcher;
  final Completer<Map<String, Object?>> completer;

  bool matches(Map<String, Object?> packet) {
    final command = packet['cmd'];
    return command is String &&
        commands.contains(command) &&
        (matcher == null || matcher!(packet));
  }
}

final class _GlobalSyncResult {
  const _GlobalSyncResult(
    this.previousCursor,
    this.nextCursor,
    this.messages,
    this.crossOrgAccessSnapshotId,
    this.accessSnapshotHighWater,
    this.connectionGeneration,
    this.accessGeneration,
  );

  final String previousCursor;
  final String nextCursor;
  final List<AppImMessage> messages;
  final String crossOrgAccessSnapshotId;
  final String accessSnapshotHighWater;
  final int connectionGeneration;
  final int accessGeneration;
}

final class AppImConnectionException implements Exception {
  const AppImConnectionException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

bool isAppImAccessSnapshotFailure(Object error) =>
    error is AppImConnectionException &&
    const {
      'IM_ACCESS_SNAPSHOT_INVALID',
      'IM_ACCESS_SNAPSHOT_UNSTABLE',
    }.contains(error.code);
