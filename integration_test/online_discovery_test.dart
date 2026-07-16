import 'package:b8im_app_flutter/src/app/b8im_app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS App 通过公网发现并验签测试线路', (tester) async {
    await tester.pumpWidget(const B8imApp());
    await tester.enterText(
      find.byKey(const ValueKey('enterprise-code')),
      'org_1',
    );
    await tester.tap(find.byKey(const ValueKey('discover-button')));

    for (var attempt = 0; attempt < 30; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('wss://ws.idev.love').evaluate().isNotEmpty) break;
    }

    expect(find.text('连接失败'), findsNothing);
    expect(find.text('https://api.idev.love'), findsWidgets);
    expect(find.text('wss://ws.idev.love'), findsOneWidget);
  });
}
