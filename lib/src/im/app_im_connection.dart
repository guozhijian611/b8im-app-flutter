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
    required this.previousGlobalSeq,
    required this.nextGlobalSeq,
    required this.syncedMessages,
  });

  final String clientId;
  final String connectionSessionId;
  final String credentialSessionId;
  final String previousGlobalSeq;
  final String nextGlobalSeq;
  final List<AppImMessage> syncedMessages;
}

final class AppImEvent {
  const AppImEvent({
    required this.command,
    required this.message,
    required this.eventId,
  });

  final String command;
  final AppImMessage? message;
  final String? eventId;
}

abstract interface class AppImRuntime {
  AppImBootstrapSnapshot get bootstrap;
  Stream<AppImEvent> get events;
  bool get isConnected;

  Future<AppImMessage> sendText({
    required int conversationType,
    required String text,
    String? conversationId,
    String? toUserId,
  });

  Future<void> close();
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
  });

  final AppSessionService sessionService;
  final ImSyncCursorGateway cursorStore;
  final ImSocketFactory socketFactory;
  final Duration timeout;

  @override
  Future<AppImRuntime> connect({
    required TenantConfig tenant,
    required AppSession session,
  }) {
    return AppImConnection.connect(
      tenant: tenant,
      session: session,
      sessionService: sessionService,
      cursorStore: cursorStore,
      socketFactory: socketFactory,
      timeout: timeout,
    );
  }
}

final class AppImConnection implements AppImRuntime {
  AppImConnection._({
    required this.tenant,
    required this.session,
    required this.sessionService,
    required this.cursorStore,
    required this.socket,
    required this.timeout,
  });

  static Future<AppImConnection> connect({
    required TenantConfig tenant,
    required AppSession session,
    required AppSessionService sessionService,
    required ImSyncCursorGateway cursorStore,
    required ImSocketFactory socketFactory,
    Duration timeout = const Duration(seconds: 12),
  }) async {
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
  final List<Map<String, Object?>> _pendingPackets = [];
  final LinkedHashSet<String> _seenEventIds = LinkedHashSet();
  StreamSubscription<Object?>? _subscription;
  Timer? _heartbeat;
  late AppImBootstrapSnapshot _bootstrap;
  bool _authenticated = false;
  bool _closed = false;

  @override
  AppImBootstrapSnapshot get bootstrap => _bootstrap;

  @override
  Stream<AppImEvent> get events => _events.stream;

  @override
  bool get isConnected => _authenticated && !_closed;

  Future<AppImBootstrapSnapshot> _authenticateAndSync() async {
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
    final sync = await _syncGlobal();
    return AppImBootstrapSnapshot(
      clientId: clientId,
      connectionSessionId: connectionSessionId,
      credentialSessionId: credential.credentialSessionId,
      previousGlobalSeq: sync.previousCursor,
      nextGlobalSeq: sync.nextCursor,
      syncedMessages: List.unmodifiable(sync.messages),
    );
  }

  Future<_GlobalSyncResult> _syncGlobal() async {
    final previous = await cursorStore.read(
      tenant.organization,
      session.user.userId,
    );
    var cursor = previous;
    final messages = <AppImMessage>[];
    final messageIds = <String>{};
    for (var page = 0; page < 100; page++) {
      final waiter = _waitFor(
        {'sync_ack', 'error'},
        matcher: (packet) {
          if (packet['cmd'] == 'error') return true;
          final data = packet['data'];
          return data is Map && data['scope'] == 'global';
        },
      );
      _send({
        'cmd': 'sync',
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
      final pageMessages = (data['messages'] as List)
          .map(AppImMessage.fromRealtime)
          .toList(growable: false);
      for (final message in pageMessages) {
        if (message.organization != tenant.organization) {
          throw const AppImConnectionException('SYNC 消息 organization 不一致');
        }
        if (messageIds.add(message.messageId)) messages.add(message);
      }
      final next = _requiredString(
        data,
        'next_after_global_seq',
        'sync_ack.next_after_global_seq',
      );
      final nextNumber = BigInt.tryParse(next);
      final cursorNumber = BigInt.tryParse(cursor);
      if (nextNumber == null ||
          cursorNumber == null ||
          nextNumber < cursorNumber) {
        throw const AppImConnectionException('SYNC global_seq 游标无效');
      }
      final hasMore = data['has_more'] as bool;
      if (hasMore && nextNumber == cursorNumber) {
        throw const AppImConnectionException('SYNC 分页游标未前进');
      }
      await cursorStore.write(tenant.organization, session.user.userId, next);
      cursor = next;
      if (!hasMore) {
        return _GlobalSyncResult(previous, cursor, messages);
      }
    }
    throw const AppImConnectionException('SYNC 分页超过安全上限');
  }

  @override
  Future<AppImMessage> sendText({
    required int conversationType,
    required String text,
    String? conversationId,
    String? toUserId,
  }) async {
    if (!isConnected) {
      throw const AppImConnectionException('IM 连接未就绪');
    }
    final normalized = text.trim();
    if (normalized.isEmpty || normalized.length > 4000) {
      throw const FormatException('文本消息长度必须为 1..4000');
    }
    final data = <String, Object?>{
      'conversation_type': conversationType,
      'message_type': 1,
      'content': {'text': normalized},
    };
    if (conversationType == 1) {
      final peer = toUserId?.trim() ?? '';
      if (peer.isEmpty) throw const FormatException('单聊缺少 to_user_id');
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
        ack['message'] == null) {
      throw const AppImConnectionException('SEND_ACK 格式无效');
    }
    final message = AppImMessage.fromRealtime(ack['message']);
    if (message.organization != tenant.organization ||
        message.senderId != session.user.userId ||
        message.clientMsgId != clientMsgId) {
      throw const AppImConnectionException('SEND_ACK 与发送请求不一致');
    }
    _events.add(
      AppImEvent(command: 'send_ack', message: message, eventId: null),
    );
    return message;
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
      if (packet.containsKey('organization') &&
          packetOrganization != tenant.organization &&
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

  void _handlePush(Map<String, Object?> packet) {
    final data = imMap(packet['data'], 'push.data');
    final eventId = _requiredString(data, 'event_id', 'push.event_id');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(eventId)) {
      throw const FormatException('push.event_id 无效');
    }
    if (!_seenEventIds.add(eventId)) return;
    if (_seenEventIds.length > 2048) _seenEventIds.remove(_seenEventIds.first);
    final message = AppImMessage.fromRealtime(data['message']);
    if (message.organization != tenant.organization) {
      throw const FormatException('push message organization 不一致');
    }
    _events.add(
      AppImEvent(command: 'push', message: message, eventId: eventId),
    );
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
    return AppImConnectionException('$code: $message');
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
    _heartbeat?.cancel();
    final exception = const AppImConnectionException('IM 连接已关闭');
    for (final waiter in List<_PacketWaiter>.from(_waiters)) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(exception);
      }
    }
    _waiters.clear();
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
  const _GlobalSyncResult(this.previousCursor, this.nextCursor, this.messages);

  final String previousCursor;
  final String nextCursor;
  final List<AppImMessage> messages;
}

final class AppImConnectionException implements Exception {
  const AppImConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}
