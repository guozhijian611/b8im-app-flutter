import 'package:b8im_app_flutter/src/discovery/tenant_config.dart';
import 'package:b8im_app_flutter/src/qr_login/app_qr_login_service.dart';
import 'package:b8im_app_flutter/src/qr_login/web_login_qr_payload.dart';
import 'package:b8im_app_flutter/src/qr_login/web_login_scanner_page.dart';
import 'package:b8im_app_flutter/src/session/app_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/tenant_fixture.dart';

const _qrId = '0123456789abcdef0123456789abcdef';
const _scanToken = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const _qrValue =
    'b8im://web-login?qr_id=$_qrId&scan_token=$_scanToken'
    '&organization=1&deployment_id=b8im-test';

void main() {
  testWidgets('同帧重复识别只 scan 一次，用户点击后才 confirm', (tester) async {
    final scanner = _FakeScanner();
    final gateway = _FakeGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: _ScannerHost(scanner: scanner, gateway: gateway),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-scanner')));
    await tester.pump();
    scanner.emit(_qrValue);
    scanner.emit(_qrValue);
    await tester.pumpAndSettle();

    expect(gateway.scanCalls, 1);
    expect(gateway.confirmCalls, 0);
    expect(scanner.stopCalls, greaterThanOrEqualTo(1));
    expect(find.text('登录 b8im 测试机构'), findsOneWidget);
    expect(find.byKey(const ValueKey('web-login-site')), findsOneWidget);
    expect(find.text('https://web.example.test'), findsOneWidget);
    expect(find.text('brow…ce-1'), findsOneWidget);
    expect(find.byKey(const ValueKey('web-login-expiry')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('web-login-cancel')));
    await tester.pumpAndSettle();
    expect(gateway.confirmCalls, 0);
    expect(scanner.startCalls, 2);

    scanner.emit(_qrValue);
    await tester.pumpAndSettle();
    expect(gateway.scanCalls, 2);
    await tester.tap(find.byKey(const ValueKey('web-login-confirm')));
    await tester.pumpAndSettle();

    expect(gateway.confirmCalls, 1);
    expect(find.text('confirmed'), findsOneWidget);
    expect(scanner.disposeCalls, 1);
  });

  testWidgets('scan 失败后明确提示并可重新扫描', (tester) async {
    final scanner = _FakeScanner();
    final gateway = _FakeGateway(scanError: StateError('network'));
    await tester.pumpWidget(
      MaterialApp(
        home: WebLoginScannerPage(
          tenant: tenantFixture(),
          session: _session(),
          gateway: gateway,
          scanner: scanner,
        ),
      ),
    );
    await tester.pump();

    scanner.emit(_qrValue);
    await tester.pumpAndSettle();
    expect(find.text('二维码校验失败，请检查网络后重新扫描'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('web-login-scan-retry')));
    await tester.pump();
    expect(scanner.startCalls, 2);
  });

  testWidgets('相机权限拒绝时显示系统设置提示', (tester) async {
    final scanner = _FakeScanner(
      startError: const AppQrScannerException(
        AppQrScannerErrorKind.permissionDenied,
        '相机权限已被拒绝，请在系统设置中允许 b8im 使用相机',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: WebLoginScannerPage(
          tenant: tenantFixture(),
          session: _session(),
          gateway: _FakeGateway(),
          scanner: scanner,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('系统设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('web-login-scan-retry')), findsOneWidget);
  });
}

final class _FakeScanner implements AppQrCodeScanner {
  _FakeScanner({this.startError});

  final AppQrScannerException? startError;
  ValueChanged<String>? _onDetect;
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;

  void emit(String value) => _onDetect?.call(value);

  @override
  Widget buildPreview({
    required ValueChanged<String> onDetect,
    required ValueChanged<AppQrScannerException> onError,
  }) {
    _onDetect = onDetect;
    return const ColoredBox(color: Colors.black);
  }

  @override
  Future<void> start() async {
    startCalls++;
    if (startError case final error?) throw error;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async => disposeCalls++;
}

final class _FakeGateway implements AppQrLoginGateway {
  _FakeGateway({this.scanError});

  final Object? scanError;
  int scanCalls = 0;
  int confirmCalls = 0;

  @override
  Future<WebLoginScanResult> scan({
    required TenantConfig tenant,
    required AppSession session,
    required WebLoginQrPayload payload,
  }) async {
    scanCalls++;
    if (scanError case final error?) throw error;
    return WebLoginScanResult(
      qrId: payload.qrId,
      organizationName: 'b8im 测试机构',
      webOrigin: Uri.parse('https://web.example.test'),
      browserDevice: 'brow…ce-1',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
    );
  }

  @override
  Future<void> confirm({
    required TenantConfig tenant,
    required AppSession session,
    required String qrId,
  }) async {
    confirmCalls++;
  }
}

final class _ScannerHost extends StatefulWidget {
  const _ScannerHost({required this.scanner, required this.gateway});

  final AppQrCodeScanner scanner;
  final AppQrLoginGateway gateway;

  @override
  State<_ScannerHost> createState() => _ScannerHostState();
}

final class _ScannerHostState extends State<_ScannerHost> {
  bool? _result;

  Future<void> _open() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WebLoginScannerPage(
          tenant: tenantFixture(),
          session: _session(),
          gateway: widget.gateway,
          scanner: widget.scanner,
        ),
      ),
    );
    if (mounted) setState(() => _result = result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          FilledButton(
            key: const ValueKey('open-scanner'),
            onPressed: _open,
            child: const Text('open'),
          ),
          if (_result != null) Text(_result! ? 'confirmed' : 'cancelled'),
        ],
      ),
    );
  }
}

AppSession _session() => const AppSession(
  accessToken: 'access-token',
  expireAt: 4102444800,
  organization: 1,
  deploymentId: 'b8im-test',
  deviceId: 'device-01',
  runtime: AppClientRuntime(os: 'ios'),
  user: AppUser(
    id: '9',
    userId: 'user-01',
    account: 'acceptance',
    nickname: '验收用户',
  ),
);
