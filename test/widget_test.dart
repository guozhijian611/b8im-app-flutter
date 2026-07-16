import 'package:b8im_app_flutter/src/app/b8im_app.dart';
import 'package:b8im_app_flutter/src/config/app_environment.dart';
import 'package:b8im_app_flutter/src/discovery/tenant_config.dart';
import 'package:b8im_app_flutter/src/discovery/tenant_discovery_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/tenant_fixture.dart';

final class _FakeDiscovery implements TenantDiscoveryGateway {
  @override
  Future<TenantConfig> discoverByDomain(String domain, {String? deviceId}) {
    return Future.value(tenantFixture());
  }

  @override
  Future<TenantConfig> discoverByEnterpriseCode(
    String enterpriseCode, {
    String? deviceId,
  }) {
    return Future.value(tenantFixture());
  }
}

void main() {
  testWidgets('使用企业码展示已验签的测试环境线路', (tester) async {
    await tester.pumpWidget(
      B8imApp(
        environment: AppEnvironment(
          discoveryBaseUri: Uri.parse('https://api.idev.love'),
          routingPublicKeys: const {'test': 'public-key'},
          initialEnterpriseCode: 'org_1',
        ),
        discoveryGateway: _FakeDiscovery(),
        deviceIdLoader: () async => '0123456789abcdef0123456789abcdef',
      ),
    );

    expect(find.text('连接你的企业'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('discover-button')));
    await tester.pumpAndSettle();

    expect(find.text('b8im 测试机构'), findsOneWidget);
    expect(find.text('https://api.idev.love'), findsWidgets);
    expect(find.text('wss://ws.idev.love'), findsOneWidget);
  });
}
