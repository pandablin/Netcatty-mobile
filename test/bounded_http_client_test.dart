import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:netcatty_mobile/infrastructure/sync/bounded_http_client.dart';

class _StreamClient extends http.BaseClient {
  _StreamClient(this.response);
  final http.StreamedResponse Function(http.BaseRequest) response;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response(request);

  @override
  void close() => closed = true;
}

void main() {
  final uri = Uri.parse('https://dav.example.test/netcatty-vault.json');

  test('rejects advertised oversized body and cancels before buffering',
      () async {
    var cancelled = false;
    final source = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    final inner = _StreamClient((_) => http.StreamedResponse(
          source.stream,
          200,
          contentLength: 100,
        ));
    final client = BoundedHttpClient(inner, limitFor: (_) => 8);
    await expectLater(client.get(uri), throwsStateError);
    expect(cancelled, isTrue);
    await source.close();
  });

  test('counts chunked bodies and cancels at the byte limit', () async {
    var cancelled = false;
    final source = StreamController<List<int>>(
      onListen: () {},
      onCancel: () => cancelled = true,
    );
    final client = BoundedHttpClient(
      _StreamClient((_) => http.StreamedResponse(source.stream, 200)),
      limitFor: (_) => 8,
    );
    final result = expectLater(client.get(uri), throwsStateError);
    source.add([1, 2, 3, 4]);
    source.add([5, 6, 7, 8]);
    source.add([9]);
    await result;
    expect(cancelled, isTrue);
    await source.close();
  });

  test('accepts exactly the limit, preserves revision/status and ownership',
      () async {
    final inner = _StreamClient((request) => http.StreamedResponse(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          206,
          request: request,
          headers: {'etag': 'revision-1'},
        ));
    final client = BoundedHttpClient(inner, limitFor: (_) => 4);
    final response = await client.get(uri);
    expect(response.bodyBytes, [1, 2, 3, 4]);
    expect(response.statusCode, 206);
    expect(response.headers['etag'], 'revision-1');
    expect(response.request?.url, uri);
    expect(inner.closed, isFalse);
    client.close();
    expect(inner.closed, isTrue);
  });
}
