import 'package:b8im_app_flutter/src/storage/im_sync_cursor_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  late SharedPreferencesAsyncPlatform? previousBackend;
  late InMemorySharedPreferencesAsync backend;

  setUp(() {
    previousBackend = SharedPreferencesAsyncPlatform.instance;
    backend = InMemorySharedPreferencesAsync.empty();
    SharedPreferencesAsyncPlatform.instance = backend;
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = previousBackend;
  });

  test('global cursor 仅在当前 store 生命周期内单调推进', () async {
    final firstRuntime = ImSyncCursorStore();

    expect(await firstRuntime.read(1, 'user-01'), '0');
    await firstRuntime.write(1, 'user-01', '10');
    expect(await firstRuntime.read(1, 'user-01'), '10');
    await expectLater(
      firstRuntime.write(1, 'user-01', '9'),
      throwsA(isA<StateError>()),
    );
    expect(await firstRuntime.read(1, 'user-01'), '10');

    final coldStart = ImSyncCursorStore();
    expect(await coldStart.read(1, 'user-01'), '0');
  });

  test('access high-water 按复合身份持久化且永不回退', () async {
    final firstRuntime = ImSyncCursorStore(
      preferences: SharedPreferencesAsync(),
    );

    expect(await firstRuntime.readAccessSnapshotHighWater(1, 'user-01'), '0');
    await firstRuntime.writeAccessSnapshotHighWater(1, 'user-01', '100');
    await firstRuntime.writeAccessSnapshotHighWater(1, 'user-01', '0');
    await firstRuntime.writeAccessSnapshotHighWater(1, 'user-01', '99');
    await firstRuntime.writeAccessSnapshotHighWater(1, 'user-01', '100');
    expect(await firstRuntime.readAccessSnapshotHighWater(1, 'user-01'), '100');
    expect(await firstRuntime.readAccessSnapshotHighWater(2, 'user-01'), '0');
    expect(await firstRuntime.readAccessSnapshotHighWater(1, 'user-02'), '0');

    await firstRuntime.writeAccessSnapshotHighWater(1, 'user-01', '101');
    final coldStart = ImSyncCursorStore(preferences: SharedPreferencesAsync());
    expect(await coldStart.read(1, 'user-01'), '0');
    expect(await coldStart.readAccessSnapshotHighWater(1, 'user-01'), '101');
  });
}
