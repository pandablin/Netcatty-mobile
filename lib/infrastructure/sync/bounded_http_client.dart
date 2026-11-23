import 'package:http/http.dart' as http;

/// Bounds streamed responses before http.Client.get/put can buffer them.
/// A server's Content-Length is only an early rejection hint; every byte is
/// counted as it arrives, including responses without a length header.
class BoundedHttpClient extends http.BaseClient {
  BoundedHttpClient(this._inner, {required this.limitFor});

  final http.Client _inner;
  final int Function(Uri uri) limitFor;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    final limit = limitFor(request.url);
    if (response.contentLength != null && response.contentLength! > limit) {
      await response.stream.listen(null).cancel();
      throw _tooLarge(limit);
    }
    return http.StreamedResponse(
      _bounded(response.stream, limit),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  Stream<List<int>> _bounded(Stream<List<int>> stream, int limit) async* {
    var received = 0;
    await for (final chunk in stream) {
      received += chunk.length;
      if (received > limit) throw _tooLarge(limit);
      yield chunk;
    }
  }

  StateError _tooLarge(int limit) =>
      StateError('云端响应超过安全大小限制（$limit 字节），已停止读取');

  @override
  void close() => _inner.close();
}
