import 'package:shared_preferences/shared_preferences.dart';

import 'im_sync_cursor_gateway.dart';

final class ImSyncCursorStore implements ImSyncCursorGateway {
  ImSyncCursorStore({SharedPreferencesAsync? preferences})
    : _preferenceStoreOverride = preferences;

  SharedPreferencesAsync? _preferenceStoreOverride;
  final Map<String, String> _runtimeCursors = {};
  Future<void> _writeQueue = Future<void>.value();

  @override
  Future<String> read(int organization, String userId) async {
    return _runtimeCursors[_runtimeCursorKey(organization, userId)] ?? '0';
  }

  @override
  Future<bool> write(
    int organization,
    String userId,
    String cursor, {
    bool Function()? isCurrent,
  }) async {
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(cursor)) {
      throw const FormatException('global_seq 游标格式无效');
    }
    if (isCurrent?.call() == false) return false;
    final key = _runtimeCursorKey(organization, userId);
    final current = _runtimeCursors[key] ?? '0';
    final comparison = BigInt.parse(cursor).compareTo(BigInt.parse(current));
    if (comparison < 0) {
      throw StateError('global_seq 游标禁止回退');
    }
    if (comparison > 0) _runtimeCursors[key] = cursor;
    return true;
  }

  @override
  Future<String> readAccessSnapshotHighWater(
    int organization,
    String userId,
  ) async {
    final value =
        await _preferenceStore.getString(_snapshotKey(organization, userId)) ??
        '0';
    return RegExp(r'^(0|[1-9][0-9]{0,19})$').hasMatch(value) ? value : '0';
  }

  @override
  Future<bool> writeAccessSnapshotHighWater(
    int organization,
    String userId,
    String snapshotId, {
    bool Function()? isCurrent,
  }) async {
    if (!RegExp(r'^(0|[1-9][0-9]{0,19})$').hasMatch(snapshotId)) {
      throw const FormatException('访问快照高水位格式无效');
    }
    return _enqueueWrite(() async {
      final current = await readAccessSnapshotHighWater(organization, userId);
      if (isCurrent?.call() == false) return false;
      if (BigInt.parse(snapshotId) > BigInt.parse(current)) {
        await _preferenceStore.setString(
          _snapshotKey(organization, userId),
          snapshotId,
        );
      }
      return true;
    });
  }

  Future<T> _enqueueWrite<T>(Future<T> Function() operation) {
    final next = _writeQueue.then((_) => operation());
    _writeQueue = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  SharedPreferencesAsync get _preferenceStore =>
      _preferenceStoreOverride ??= SharedPreferencesAsync();

  String _runtimeCursorKey(int organization, String userId) =>
      '$organization:$userId';

  String _snapshotKey(int organization, String userId) =>
      'b8im.im.cross_org_access_high_water.$organization.$userId';
}
