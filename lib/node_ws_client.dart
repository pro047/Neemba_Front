import 'dart:io';
import 'dart:typed_data';

class NodeWsClient {
  WebSocket? _webSocket;

  NodeWsClient();

  Future<void> connect(Int16List data) async {
    _webSocket = await WebSocket.connect('ws://localhost:3000/api/mic');
    _webSocket?.add(data);
  }

  Future<void> close() async {
    await _webSocket?.close();
  }
}
