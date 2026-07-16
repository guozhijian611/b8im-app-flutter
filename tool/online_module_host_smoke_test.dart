import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'online_module_host_smoke.dart' as smoke;

void main() {
  test('公网 App 模块宿主 resolve + file_media 打开', () async {
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
