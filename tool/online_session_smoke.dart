import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:b8im_app_flutter/src/discovery/tenant_discovery_client.dart';
import 'package:b8im_app_flutter/src/im/im_bootstrap_client.dart';
import 'package:b8im_app_flutter/src/modules/client_module_registry.dart';
import 'package:b8im_app_flutter/src/network/app_api_client.dart';
import 'package:b8im_app_flutter/src/security/routing_signature_verifier.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:b8im_app_flutter/src/session/app_session_bootstrapper.dart';
import 'package:b8im_app_flutter/src/session/app_session_service.dart';

Future<void> main() async {
  final environment = Platform.environment;
  final enterpriseCode = environment['B8IM_ENTERPRISE_CODE']?.trim() ?? '';
  final keyJson = environment['B8IM_ROUTING_PUBLIC_KEYS']?.trim() ?? '';
  final account = environment['B8IM_APP_ACCOUNT']?.trim() ?? '';
  final password = environment['B8IM_APP_PASSWORD'] ?? '';
  final os = environment['B8IM_APP_OS']?.trim() ?? 'ios';
  final discoveryBaseUrl =
      environment['B8IM_DISCOVERY_BASE_URL']?.trim() ?? 'https://api.idev.love';
  if (enterpriseCode.isEmpty ||
      keyJson.isEmpty ||
      account.isEmpty ||
      password.isEmpty) {
    stderr.writeln(
      '需要 B8IM_ENTERPRISE_CODE、B8IM_ROUTING_PUBLIC_KEYS、'
      'B8IM_APP_ACCOUNT 和 B8IM_APP_PASSWORD 环境变量',
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
    final result =
        await AppSessionBootstrapper(
          sessionService: service,
          moduleRegistry: ClientModuleRegistry(const []),
          imClient: ImBootstrapClient(sessionService: service),
        ).connect(
          tenant: tenant,
          account: account,
          password: password,
          deviceId: deviceId,
          runtime: AppClientRuntime(os: os),
        );

    stdout.writeln(
      jsonEncode({
        'organization': tenant.organization,
        'deployment_id': tenant.deploymentId,
        'routing_version': tenant.routing.routingVersion,
        'api': apiUri.toString(),
        'im': imUri.toString(),
        'client_family': 'app',
        'os': os,
        'user_id': result.session.user.userId,
        'resolved_module_count': result.modules.length,
        'im_client_id': result.im.clientId,
        'previous_global_seq': result.im.previousGlobalSeq,
        'next_global_seq': result.im.nextGlobalSeq,
        'synced_message_count': result.im.syncedMessageCount,
        'auth_sync_completed': true,
      }),
    );
  } finally {
    api.close();
    discovery.close();
  }
}

String _randomHex(int length) {
  final random = Random.secure();
  const alphabet = '0123456789abcdef';
  return List.generate(length, (_) => alphabet[random.nextInt(16)]).join();
}
