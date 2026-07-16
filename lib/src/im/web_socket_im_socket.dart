import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'im_bootstrap_client.dart';

final class WebSocketImSocket implements ImSocket {
  WebSocketImSocket._(this._channel);

  static Future<WebSocketImSocket> connect(
    Uri uri, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final channel = IOWebSocketChannel.connect(uri, connectTimeout: timeout);
    await channel.ready.timeout(timeout);
    return WebSocketImSocket._(channel);
  }

  final WebSocketChannel _channel;

  @override
  Stream<Object?> get stream => _channel.stream;

  @override
  void send(Object? value) => _channel.sink.add(value);

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}
