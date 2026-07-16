import 'package:shared_preferences/shared_preferences.dart';

abstract interface class ImSyncCursorGateway {
  Future<String> read(int organization, String userId);
  Future<void> write(int organization, String userId, String cursor);
}

final class ImSyncCursorStore implements ImSyncCursorGateway {
  ImSyncCursorStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String> read(int organization, String userId) async {
    final value =
        await _preferences.getString(_key(organization, userId)) ?? '0';
    return RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value) ? value : '0';
  }

  @override
  Future<void> write(int organization, String userId, String cursor) async {
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(cursor)) {
      throw const FormatException('global_seq 游标格式无效');
    }
    await _preferences.setString(_key(organization, userId), cursor);
  }

  String _key(int organization, String userId) =>
      'b8im.im.global_seq.$organization.$userId';
}
