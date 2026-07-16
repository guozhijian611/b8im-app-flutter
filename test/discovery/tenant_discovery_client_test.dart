import 'dart:convert';

import 'package:b8im_app_flutter/src/discovery/tenant_config.dart';
import 'package:b8im_app_flutter/src/discovery/tenant_discovery_client.dart';
import 'package:b8im_app_flutter/src/security/canonical_json.dart';
import 'package:b8im_app_flutter/src/security/routing_signature_verifier.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/tenant_fixture.dart';

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

void main() {
  test('通过企业码发现 App 线路并校验签名', () async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final data = tenantDataFixture();
    final signature = await algorithm.sign(
      utf8.encode(canonicalJson(TenantConfig.signaturePayload(data))),
      keyPair: keyPair,
    );
    data['routing_signature'] = {
      'alg': 'Ed25519',
      'kid': 'test-key',
      'canonicalization': 'JCS-RFC8785',
      'value': _base64Url(signature.bytes),
    };

    final httpClient = MockClient((request) async {
      expect(request.url.scheme, 'https');
      expect(request.url.host, 'api.idev.love');
      expect(request.url.path, '/saimulti/appInfo');
      expect(request.url.queryParameters['enterprise_code'], 'org_1');
      expect(request.url.queryParameters['client_family'], 'app');
      expect(
        request.headers['traceparent'],
        matches(RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-01$')),
      );
      expect(request.headers['X-Device-Id'], 'device-1');
      return http.Response(
        jsonEncode({'code': 200, 'message': 'ok', 'data': data}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = TenantDiscoveryClient(
      discoveryBaseUri: Uri.parse('https://api.idev.love'),
      signatureVerifier: RoutingSignatureVerifier({
        'test-key': _base64Url(publicKey.bytes),
      }),
      httpClient: httpClient,
    );

    final tenant = await client.discoverByEnterpriseCode(
      'ORG_1',
      deviceId: 'device-1',
    );

    expect(tenant.organization, 1);
    expect(tenant.enterpriseCode, 'org_1');
    expect(tenant.routing.primary.endpoints.apiServerUri.host, 'api.idev.love');
    expect(tenant.routing.primary.endpoints.imServerUri.host, 'ws.idev.love');
  });

  test('拒绝未配置 App 线路的线上错误响应', () async {
    final client = TenantDiscoveryClient(
      discoveryBaseUri: Uri.parse('https://api.idev.love'),
      signatureVerifier: RoutingSignatureVerifier(const {}),
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({'code': 404, 'message': '当前机构尚未发布该客户端线路。'}),
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      client.discoverByEnterpriseCode('org_1'),
      throwsA(
        isA<TenantDiscoveryException>().having(
          (error) => error.message,
          'message',
          contains('尚未发布'),
        ),
      ),
    );
  });
}
