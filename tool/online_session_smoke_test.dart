import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'online_session_smoke.dart' as smoke;

void main() {
  test('公网 Android/iOS App 会话、回执与媒体链路', () async {
    final previousExitCode = exitCode;
    exitCode = 0;
    try {
      await smoke.main();
      expect(exitCode, 0);
    } finally {
      exitCode = previousExitCode;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
