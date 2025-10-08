import 'package:web_socket_channel/io.dart';

class WsClient {
  IOWebSocketChannel? _channel;

  WsClient();

  Future<void> connect({
    required String sessionId,
    required String webSocketUrl,
    required void Function(String) onText,
  }) async {
    final url = Uri.parse(webSocketUrl);
    //   webSocketUrl.replaceAll('#', ''),
    // ).replace(scheme: 'wss');
    print('webSocket url : $url');
    _channel = IOWebSocketChannel.connect(url);
    _channel!.stream.listen(
      (event) {
        print('event : $event');
        onText(event);
      },
      onDone: () => {print('ws closed')},
      onError: (e) => print('ws error $e'),
    );
  }

  Future<void> close() async {
    await _channel?.sink.close();
  }
}
