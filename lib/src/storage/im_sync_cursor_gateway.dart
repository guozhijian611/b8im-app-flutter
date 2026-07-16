abstract interface class ImSyncCursorGateway {
  Future<String> read(int organization, String userId);
  Future<void> write(int organization, String userId, String cursor);
}
