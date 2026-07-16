import 'dart:async';
import 'dart:convert';

import '../discovery/tenant_config.dart';
import '../observability/trace_context.dart';
import '../session/app_session.dart';
import '../session/app_session_service.dart';
import '../storage/im_sync_cursor_gateway.dart';

abstract interface class ImSocket {
  Stream<Object?> get stream;
  void send(Object? value);
  Future<void> close();
}

typedef ImSocketFactory = Future<ImSocket> Function(Uri uri);

final class ImBootstrapResult {
  const ImBootstrapResult({
    required this.clientId,
    required this.connectionSessionId,
    required this.credentialSessionId,
    required this.previousGlobalSeq,
    required this.nextGlobalSeq,
    required this.syncedMessageCount,
    required this.hasMore,
  });

  final String clientId;
  final String connectionSessionId;
  final String credentialSessionId;
  final String previousGlobalSeq;
  final String nextGlobalSeq;
  final int syncedMessageCount;
  final bool hasMore;
}

final class ImBootstrapClient {
  ImBootstrapClient({
    required this.sessionService,
    required this.cursorStore,
    required this.socketFactory,
    this.timeout = const Duration(seconds: 12),
  });

  final AppSessionService sessionService;
  final ImSyncCursorGateway cursorStore;
  final ImSocketFactory socketFactory;
  final Duration timeout;

  Future<ImBootstrapResult> bootstrap({
    required TenantConfig tenant,
    required AppSession session,
  }) async {
    final uri = tenant.routing.primary.endpoints.imServerUri;
    final socket = await socketFactory(uri).timeout(timeout);
    final packets = StreamIterator<Object?>(socket.stream);
    try {
      final challenge = await _nextPacket(packets, {'auth'});
      final clientId = _requiredString(
        _map(challenge['data'], 'auth.data'),
        'client_id',
      );
      final credential = await sessionService.issueImChallenge(
        tenant: tenant,
        session: session,
        clientId: clientId,
      );
      final authTrace = TraceContext.root();
      socket.send(
        jsonEncode({
          'cmd': 'auth',
          'organization': tenant.organization,
          'traceparent': authTrace.traceparent,
          'data': {
            'token': credential.token,
            'device_id': session.deviceId,
            'client_family': 'app',
            'os': session.runtime.os,
          },
        }),
      );
      final authAck = await _nextPacket(packets, {'auth_ack'});
      final authData = _map(authAck['data'], 'auth_ack.data');
      if (authData['ok'] != true ||
          authAck['organization'] != tenant.organization ||
          authData['user_id'] != session.user.userId ||
          authData['device_id'] != session.deviceId ||
          authData['client_id'] != clientId ||
          authData['credential_session_id'] != credential.credentialSessionId ||
          authData['client_family'] != 'app' ||
          authData['os'] != session.runtime.os) {
        throw const ImBootstrapException('AUTH_ACK 与 App 会话不一致');
      }
      final connectionSessionId = _requiredString(authData, 'session_id');

      final cursor = await cursorStore.read(
        tenant.organization,
        session.user.userId,
      );
      final syncTrace = authTrace.child();
      socket.send(
        jsonEncode({
          'cmd': 'sync',
          'organization': tenant.organization,
          'traceparent': syncTrace.traceparent,
          'data': {'after_global_seq': cursor, 'limit': 100},
        }),
      );
      final syncAck = await _nextPacket(packets, {'sync_ack'});
      final syncData = _map(syncAck['data'], 'sync_ack.data');
      if (syncAck['organization'] != tenant.organization ||
          syncData['scope'] != 'global' ||
          syncData['messages'] is! List ||
          syncData['has_more'] is! bool) {
        throw const ImBootstrapException('SYNC_ACK 格式无效');
      }
      final nextCursor = _requiredString(syncData, 'next_after_global_seq');
      if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(nextCursor)) {
        throw const ImBootstrapException('SYNC_ACK global_seq 游标无效');
      }
      await cursorStore.write(
        tenant.organization,
        session.user.userId,
        nextCursor,
      );

      return ImBootstrapResult(
        clientId: clientId,
        connectionSessionId: connectionSessionId,
        credentialSessionId: credential.credentialSessionId,
        previousGlobalSeq: cursor,
        nextGlobalSeq: nextCursor,
        syncedMessageCount: (syncData['messages'] as List).length,
        hasMore: syncData['has_more'] as bool,
      );
    } finally {
      await packets.cancel();
      await socket.close();
    }
  }

  Future<Map<String, Object?>> _nextPacket(
    StreamIterator<Object?> packets,
    Set<String> expected,
  ) async {
    while (await packets.moveNext().timeout(timeout)) {
      final raw = packets.current;
      if (raw is! String) continue;
      final packet = _map(jsonDecode(raw), 'IM packet');
      final command = packet['cmd'];
      if (command == 'error') {
        final data = _map(packet['data'], 'error.data');
        throw ImBootstrapException(
          '${data['code'] ?? 'IM_ERROR'}: ${data['message'] ?? 'IM 请求失败'}',
        );
      }
      if (command is String && expected.contains(command)) return packet;
    }
    throw ImBootstrapException('IM 连接在等待 ${expected.join('/')} 时关闭');
  }

  static Map<String, Object?> _map(Object? value, String field) {
    if (value is! Map) throw ImBootstrapException('$field 格式无效');
    return value.map((key, item) => MapEntry(key.toString(), item));
  }

  static String _requiredString(Map<String, Object?> value, String field) {
    final item = value[field];
    if (item is! String || item.trim().isEmpty) {
      throw ImBootstrapException('$field 格式无效');
    }
    return item.trim();
  }
}

final class ImBootstrapException implements Exception {
  const ImBootstrapException(this.message);

  final String message;

  @override
  String toString() => message;
}
