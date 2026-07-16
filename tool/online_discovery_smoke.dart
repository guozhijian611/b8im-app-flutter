import 'dart:convert';
import 'dart:io';

import 'package:b8im_app_flutter/src/discovery/tenant_discovery_client.dart';
import 'package:b8im_app_flutter/src/security/routing_signature_verifier.dart';

Future<void> main() async {
  final enterpriseCode =
      Platform.environment['B8IM_ENTERPRISE_CODE']?.trim() ?? '';
  final keyJson =
      Platform.environment['B8IM_ROUTING_PUBLIC_KEYS']?.trim() ?? '';
  final discoveryBaseUrl =
      Platform.environment['B8IM_DISCOVERY_BASE_URL']?.trim() ??
      'https://api.idev.love';
  if (enterpriseCode.isEmpty || keyJson.isEmpty) {
    stderr.writeln('需要 B8IM_ENTERPRISE_CODE 和 B8IM_ROUTING_PUBLIC_KEYS 环境变量');
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
  final client = TenantDiscoveryClient(
    discoveryBaseUri: Uri.parse(discoveryBaseUrl),
    signatureVerifier: RoutingSignatureVerifier(keys),
  );
  try {
    final tenant = await client.discoverByEnterpriseCode(enterpriseCode);
    final api = tenant.routing.primary.endpoints.apiServerUri;
    final im = tenant.routing.primary.endpoints.imServerUri;
    if (api.host != 'api.idev.love' || im.host != 'ws.idev.love') {
      throw StateError('线上测试线路地址不符合预期: api=$api im=$im');
    }
    stdout.writeln(
      jsonEncode({
        'organization': tenant.organization,
        'deployment_id': tenant.deploymentId,
        'client_family': 'app',
        'routing_version': tenant.routing.routingVersion,
        'api': api.toString(),
        'im': im.toString(),
        'signature_verified': true,
      }),
    );
  } finally {
    client.close();
  }
}
