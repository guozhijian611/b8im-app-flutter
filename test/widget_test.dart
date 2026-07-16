import 'package:b8im_app_flutter/src/app/b8im_app.dart';
import 'package:b8im_app_flutter/src/config/app_environment.dart';
import 'package:b8im_app_flutter/src/discovery/tenant_config.dart';
import 'package:b8im_app_flutter/src/discovery/tenant_discovery_client.dart';
import 'package:b8im_app_flutter/src/im/im_bootstrap_client.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:b8im_app_flutter/src/session/app_session_bootstrapper.dart';
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

final class _FakeSessionBootstrap implements AppSessionBootstrapGateway {
  @override
  Future<AppSessionBootstrapResult> connect({
    required TenantConfig tenant,
    required String account,
    required String password,
    required String deviceId,
    required AppClientRuntime runtime,
  }) async {
    expect(account, 'acceptance');
    expect(password, 'secret');
    expect(deviceId, '0123456789abcdef0123456789abcdef');
    expect(runtime.os, 'ios');
    return AppSessionBootstrapResult(
      session: AppSession(
        accessToken: 'token',
        expireAt: 4102444800,
        organization: tenant.organization,
        deploymentId: tenant.deploymentId,
        deviceId: deviceId,
        runtime: runtime,
        user: const AppUser(
          id: '9',
          userId: 'user-01',
          account: 'acceptance',
          nickname: '验收用户',
        ),
      ),
      modules: const [],
      im: const ImBootstrapResult(
        clientId: 'client-01',
        connectionSessionId: 'connection-01',
        credentialSessionId: 'credential-01',
        previousGlobalSeq: '0',
        nextGlobalSeq: '7',
        syncedMessageCount: 2,
        hasMore: false,
      ),
    );
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
        sessionBootstrapGateway: _FakeSessionBootstrap(),
        runtime: const AppClientRuntime(os: 'ios'),
      ),
    );

    expect(find.text('连接你的企业'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('discover-button')));
    await tester.pumpAndSettle();

    expect(find.text('b8im 测试机构'), findsOneWidget);
    expect(find.text('https://api.idev.love'), findsWidgets);
    expect(find.text('wss://ws.idev.love'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('login-account')).first,
      'acceptance',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login-password')).first,
      'secret',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('login-button')).first,
    );
    await tester.tap(find.byKey(const ValueKey('login-button')).first);
    await tester.pumpAndSettle();

    expect(find.text('AUTH + SYNC 已完成'), findsOneWidget);
    expect(find.text('验收用户 (acceptance)'), findsOneWidget);
    expect(find.text('0 → 7'), findsOneWidget);
  });
}
