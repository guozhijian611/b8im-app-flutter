import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:b8im_app_flutter/src/discovery/tenant_discovery_client.dart';
import 'package:b8im_app_flutter/src/im/app_im_connection.dart';
import 'package:b8im_app_flutter/src/im/im_socket.dart';
import 'package:b8im_app_flutter/src/messaging/app_im_models.dart';
import 'package:b8im_app_flutter/src/messaging/app_messaging_service.dart';
import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/security/routing_signature_verifier.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:b8im_app_flutter/src/session/app_session_service.dart';
import 'package:b8im_app_flutter/src/storage/im_sync_cursor_gateway.dart';

Future<void> main() async {
  final environment = Platform.environment;
  final enterpriseCode = environment['B8IM_ENTERPRISE_CODE']?.trim() ?? '';
  final keyJson = environment['B8IM_ROUTING_PUBLIC_KEYS']?.trim() ?? '';
  final account = environment['B8IM_APP_ACCOUNT']?.trim() ?? '';
  final password = environment['B8IM_APP_PASSWORD'] ?? '';
  final peerUserId = environment['B8IM_APP_PEER_USER_ID']?.trim() ?? '';
  final peerAccount = environment['B8IM_APP_PEER_ACCOUNT']?.trim() ?? '';
  final peerPassword = environment['B8IM_APP_PEER_PASSWORD'] ?? '';
  final crossOrganizationUserId =
      environment['B8IM_APP_CROSS_ORG_USER_ID']?.trim() ?? '';
  final os = environment['B8IM_APP_OS']?.trim() ?? 'ios';
  final discoveryBaseUrl =
      environment['B8IM_DISCOVERY_BASE_URL']?.trim() ?? 'https://api.idev.love';
  if (enterpriseCode.isEmpty ||
      keyJson.isEmpty ||
      account.isEmpty ||
      password.isEmpty ||
      peerUserId.isEmpty ||
      peerAccount.isEmpty ||
      peerPassword.isEmpty ||
      crossOrganizationUserId.isEmpty) {
    stderr.writeln(
      '需要 B8IM_ENTERPRISE_CODE、B8IM_ROUTING_PUBLIC_KEYS、'
      'B8IM_APP_ACCOUNT、B8IM_APP_PASSWORD、B8IM_APP_PEER_USER_ID、'
      'B8IM_APP_PEER_ACCOUNT、B8IM_APP_PEER_PASSWORD 和 '
      'B8IM_APP_CROSS_ORG_USER_ID 环境变量',
    );
    exitCode = 64;
    return;
  }
  if (!const {'android', 'ios'}.contains(os)) {
    stderr.writeln('B8IM_APP_OS 仅支持 android 或 ios');
    exitCode = 64;
    return;
  }

  final decodedKeys = jsonDecode(keyJson);
  if (decodedKeys is! Map) {
    stderr.writeln('B8IM_ROUTING_PUBLIC_KEYS 必须是 JSON 对象');
    exitCode = 64;
    return;
  }
  final keys = decodedKeys.map(
    (key, value) => MapEntry(key.toString(), value.toString()),
  );
  final discovery = TenantDiscoveryClient(
    discoveryBaseUri: Uri.parse(discoveryBaseUrl),
    signatureVerifier: RoutingSignatureVerifier(keys),
  );
  final api = AppApiClient();
  AppImRuntime? connection;
  AppImRuntime? peerConnection;
  StreamSubscription<AppImEvent>? senderEventSubscription;
  final senderReceipts = <AppImReceipt>[];
  final senderConversationReads = <AppImConversationReadState>[];
  try {
    final deviceId = _randomHex(32);
    final tenant = await discovery.discoverByEnterpriseCode(
      enterpriseCode,
      deviceId: deviceId,
    );
    final apiUri = tenant.routing.primary.endpoints.apiServerUri;
    final imUri = tenant.routing.primary.endpoints.imServerUri;
    if (apiUri.host != 'api.idev.love' || imUri.host != 'ws.idev.love') {
      throw StateError('测试线路地址不符合预期: api=$apiUri im=$imUri');
    }
    final service = AppSessionService(api);
    final session = await service.login(
      tenant: tenant,
      account: account,
      password: password,
      deviceId: deviceId,
      runtime: AppClientRuntime(os: os),
    );
    final clientConfig = await service.fetchClientConfig(
      tenant: tenant,
      session: session,
    );
    final projectedModuleCount = _validateClientConfig(
      clientConfig,
      tenant.organization,
      tenant.deploymentId,
    );
    connection = await AppImConnector(
      sessionService: service,
      cursorStore: _MemoryCursorStore(),
      socketFactory: _CommandLineImSocket.connect,
    ).connect(tenant: tenant, session: session);
    final initialClientId = connection.bootstrap.clientId;
    await connection.reconnect();
    final reconnectedClientId = connection.bootstrap.clientId;
    if (reconnectedClientId == initialClientId || !connection.isConnected) {
      throw StateError('App 主动重连未建立新的 WSS 会话');
    }
    final peerSession = await service.login(
      tenant: tenant,
      account: peerAccount,
      password: peerPassword,
      deviceId: _randomHex(32),
      runtime: AppClientRuntime(os: os),
    );
    if (peerSession.user.userId != peerUserId) {
      throw StateError(
        '收件账号 user_id 与 B8IM_APP_PEER_USER_ID 不一致: '
        '${peerSession.user.userId}',
      );
    }
    peerConnection = await AppImConnector(
      sessionService: service,
      cursorStore: _MemoryCursorStore(),
      socketFactory: _CommandLineImSocket.connect,
    ).connect(tenant: tenant, session: peerSession);
    senderEventSubscription = connection.events.listen((event) {
      if (event.receipt case final receipt?) senderReceipts.add(receipt);
      if (event.conversationRead case final read?) {
        senderConversationReads.add(read);
      }
    });
    final probeText = 'app-smoke-${DateTime.now().millisecondsSinceEpoch}';
    final pushFuture = peerConnection.events
        .firstWhere(
          (event) =>
              event.command == 'push' &&
              event.message?.senderId == session.user.userId &&
              event.message?.displayText == probeText,
        )
        .timeout(const Duration(seconds: 12));
    final sent = await connection.sendText(
      conversationType: 1,
      toUserId: peerUserId,
      text: probeText,
    );
    final pushed = await pushFuture;
    if (pushed.message?.messageId != sent.messageId || pushed.eventId == null) {
      throw StateError('收件端 PUSH 与 SEND_ACK 消息不一致');
    }
    final delivered = await _waitForReceipt(
      senderReceipts,
      sent.messageId,
      AppImDeliveryStatus.delivered,
    );
    await peerConnection.acknowledge(
      messageId: sent.messageId,
      status: AppImDeliveryStatus.read,
    );
    await peerConnection.markConversationRead(
      conversationId: sent.conversationId,
      lastReadMessageId: sent.messageId,
    );
    final readReceipt = await _waitForReceipt(
      senderReceipts,
      sent.messageId,
      AppImDeliveryStatus.read,
    );
    final conversationRead = await _waitForConversationRead(
      senderConversationReads,
      sent.conversationId,
      peerUserId,
      sent.messageSeq,
    );
    String crossOrganizationErrorCode;
    try {
      await connection.sendText(
        conversationType: 1,
        toUserId: crossOrganizationUserId,
        text: 'cross-org-rejection-${DateTime.now().millisecondsSinceEpoch}',
      );
      throw StateError('跨 organization 用户发送未被 IM 拒绝');
    } on AppImConnectionException catch (error) {
      crossOrganizationErrorCode = error.code ?? '';
      if (crossOrganizationErrorCode != 'SEND_SINGLE_RECEIVER_INVALID') {
        rethrow;
      }
    }
    final messaging = AppMessagingService(api);
    final conversations = await messaging.fetchConversations(
      tenant: tenant,
      session: session,
    );
    final conversation = conversations
        .where((item) => item.conversationId == sent.conversationId)
        .firstOrNull;
    if (conversation == null || conversation.peerUser?.userId != peerUserId) {
      throw StateError('SEND_ACK 会话未出现在 App 会话列表');
    }
    final page = await messaging.fetchMessages(
      tenant: tenant,
      session: session,
      conversationId: sent.conversationId,
      limit: 100,
    );
    final historyMessage = page.messages
        .where((message) => message.messageId == sent.messageId)
        .firstOrNull;
    if (historyMessage == null || historyMessage.displayText != probeText) {
      throw StateError('SEND_ACK 消息未出现在 App HTTP 历史分页');
    }
    if (historyMessage.deliveryStatus != AppImDeliveryStatus.read) {
      throw StateError('App HTTP 历史未恢复持久化 read 回执状态');
    }
    await messaging.markRead(
      tenant: tenant,
      session: session,
      conversationId: sent.conversationId,
    );
    final im = connection.bootstrap;

    stdout.writeln(
      jsonEncode({
        'organization': tenant.organization,
        'deployment_id': tenant.deploymentId,
        'routing_version': tenant.routing.routingVersion,
        'api': apiUri.toString(),
        'im': imUri.toString(),
        'client_family': 'app',
        'os': os,
        'user_id': session.user.userId,
        'projected_module_count': projectedModuleCount,
        'im_client_id': im.clientId,
        'initial_im_client_id': initialClientId,
        'reconnected_im_client_id': reconnectedClientId,
        'reconnect_completed': true,
        'previous_global_seq': im.previousGlobalSeq,
        'next_global_seq': im.nextGlobalSeq,
        'synced_message_count': im.syncedMessages.length,
        'auth_sync_completed': true,
        'conversation_count': conversations.length,
        'sent_message_id': sent.messageId,
        'sent_conversation_id': sent.conversationId,
        'sent_message_seq': sent.messageSeq,
        'sent_global_seq': sent.globalSeq,
        'send_ack_completed': true,
        'peer_user_id': peerSession.user.userId,
        'peer_push_event_id': pushed.eventId,
        'peer_push_verified': true,
        'delivered_receipt_status': delivered.status.name,
        'read_receipt_status': readReceipt.status.name,
        'conversation_read_seq': conversationRead.lastReadSeq,
        'receipt_recovery_verified': true,
        'cross_organization_error_code': crossOrganizationErrorCode,
        'cross_organization_rejected': true,
        'http_history_verified': true,
        'http_delivery_status': historyMessage.deliveryStatus?.name,
        'mark_read_completed': true,
      }),
    );
  } finally {
    await senderEventSubscription?.cancel();
    await peerConnection?.close();
    await connection?.close();
    api.close();
    discovery.close();
  }
}

Future<AppImReceipt> _waitForReceipt(
  List<AppImReceipt> receipts,
  String messageId,
  AppImDeliveryStatus expected,
) async {
  for (var attempt = 0; attempt < 120; attempt++) {
    for (final receipt in receipts.reversed) {
      if (receipt.messageId == messageId &&
          receipt.status.rank >= expected.rank) {
        return receipt;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('等待 ${expected.name} 回执超时');
}

Future<AppImConversationReadState> _waitForConversationRead(
  List<AppImConversationReadState> states,
  String conversationId,
  String userId,
  int minimumSeq,
) async {
  for (var attempt = 0; attempt < 120; attempt++) {
    for (final state in states.reversed) {
      if (state.conversationId == conversationId &&
          state.userId == userId &&
          state.lastReadSeq >= minimumSeq) {
        return state;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('等待 conversation_read 回执超时');
}

int _validateClientConfig(
  Object? value,
  int organization,
  String deploymentId,
) {
  if (value is! Map) throw const FormatException('客户端配置不是对象');
  final config = value.map((key, item) => MapEntry(key.toString(), item));
  if (config['organization'].toString() != organization.toString() ||
      config['deployment_id'] != deploymentId ||
      config['version'] is! int ||
      config['features'] is! Map ||
      config['modules'] is! List ||
      config['tabbar'] is! List) {
    throw const FormatException('客户端配置与 App 登录上下文不一致');
  }
  return (config['modules'] as List).length;
}

final class _CommandLineImSocket implements ImSocket {
  _CommandLineImSocket(this._socket, {required this._debug});

  static Future<_CommandLineImSocket> connect(Uri uri) async {
    final socket = await WebSocket.connect(
      uri.toString(),
    ).timeout(const Duration(seconds: 12));
    return _CommandLineImSocket(
      socket,
      debug: Platform.environment['B8IM_IM_DEBUG'] == '1',
    );
  }

  final WebSocket _socket;
  final bool _debug;

  @override
  Stream<Object?> get stream => _socket.transform(
    StreamTransformer.fromHandlers(
      handleData: (data, sink) {
        if (_debug) stderr.writeln('IM <= $data');
        sink.add(data);
      },
      handleError: (error, stackTrace, sink) {
        if (_debug) stderr.writeln('IM !! $error');
        sink.addError(error, stackTrace);
      },
      handleDone: (sink) {
        if (_debug) {
          stderr.writeln(
            'IM <= CLOSE code=${_socket.closeCode} reason=${_socket.closeReason}',
          );
        }
        sink.close();
      },
    ),
  );

  @override
  void send(Object? value) {
    if (_debug) stderr.writeln('IM => ${_redactOutbound(value)}');
    _socket.add(value);
  }

  Object? _redactOutbound(Object? value) {
    if (value is! String) return value;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map && decoded['cmd'] == 'auth') {
        final copy = Map<String, Object?>.from(decoded);
        final rawData = copy['data'];
        if (rawData is Map) {
          copy['data'] = {...rawData, 'token': '<redacted>'};
        }
        return jsonEncode(copy);
      }
    } on FormatException {
      // 原始值仍交由协议层处理；调试输出只做尽力脱敏。
    }
    return value;
  }

  @override
  Future<void> close() async => _socket.close();
}

final class _MemoryCursorStore implements ImSyncCursorGateway {
  String _value = '0';

  @override
  Future<String> read(int organization, String userId) async => _value;

  @override
  Future<void> write(int organization, String userId, String cursor) async {
    _value = cursor;
  }
}

String _randomHex(int length) {
  final random = Random.secure();
  const alphabet = '0123456789abcdef';
  return List.generate(length, (_) => alphabet[random.nextInt(16)]).join();
}
