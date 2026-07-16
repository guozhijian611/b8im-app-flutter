import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

final class DeviceIdentityStore {
  DeviceIdentityStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const _storageKey = 'b8im.device_id';
  final SharedPreferencesAsync _preferences;

  Future<String> loadOrCreate() async {
    final existing = (await _preferences.getString(_storageKey))?.trim() ?? '';
    if (RegExp(r'^[a-f0-9]{32}$').hasMatch(existing)) return existing;

    final random = Random.secure();
    final deviceId = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    await _preferences.setString(_storageKey, deviceId);
    return deviceId;
  }
}
