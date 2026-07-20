abstract interface class ImSyncCursorGateway {
  Future<String> read(int organization, String userId);
  Future<bool> write(
    int organization,
    String userId,
    String cursor, {
    bool Function()? isCurrent,
  });
  Future<String> readAccessSnapshotHighWater(int organization, String userId);
  Future<bool> writeAccessSnapshotHighWater(
    int organization,
    String userId,
    String snapshotId, {
    bool Function()? isCurrent,
  });
}
