abstract interface class ImSocket {
  Stream<Object?> get stream;
  void send(Object? value);
  Future<void> close();
}

typedef ImSocketFactory = Future<ImSocket> Function(Uri uri);
