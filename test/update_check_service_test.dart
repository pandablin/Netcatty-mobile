import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/infrastructure/update_check_service.dart';

Map<String, Object?> release(
  String tag, {
  String? url,
  bool draft = false,
  bool prerelease = false,
}) =>
    {
      'tag_name': tag,
      'html_url': url ??
          'https://github.com/pandablin/Netcatty-mobile/releases/tag/$tag',
      'draft': draft,
      'prerelease': prerelease,
    };

UpdateCheckService serviceFor(List<Object?> releases) => UpdateCheckService(
      client: MockClient((_) async => http.Response(jsonEncode(releases), 200)),
    );

void main() {
  test('matching app version checks only the fork release list', () async {
    late http.Request captured;
    final service = UpdateCheckService(
      client: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode([release('v1.2.2')]), 200);
      }),
    );

    final result = await service.check('1.2.2');

    expect(captured.url.toString(),
        'https://api.github.com/repos/pandablin/Netcatty-mobile/releases?per_page=30');
    expect(captured.url, UpdateCheckService.latestReleaseApi);
    expect(captured.headers['accept'], 'application/vnd.github+json');
    expect(captured.headers.containsKey('authorization'), isFalse);
    expect(result.currentVersion, '1.2.2');
    expect(result.latestVersion, '1.2.2');
    expect(result.isLatest, isTrue);
    expect(result.updateAvailable, isFalse);
    expect(result.isDevelopmentVersion, isFalse);
    expect(result.releaseUri.toString(),
        'https://github.com/pandablin/Netcatty-mobile/releases/tag/v1.2.2');
  });

  test('fork prereleases remain available when there is no stable release',
      () async {
    final service = serviceFor([
      release('v1.9.4', prerelease: true),
      release('v1.10.0', prerelease: true),
      release('v1.9.5', prerelease: true),
    ]);

    final result = await service.check('1.9.5');

    expect(result.latestVersion, '1.10.0');
    expect(result.updateAvailable, isTrue);
    expect(result.releaseUri.toString(),
        'https://github.com/pandablin/Netcatty-mobile/releases/tag/v1.10.0');
  });

  test('selects the highest valid semantic version and skips drafts', () async {
    final service = serviceFor([
      release('v1.11.0-beta.2', prerelease: true),
      release('v90.0.0', draft: true),
      release('v1.10.0'),
      release('v1.11.0-beta.10', prerelease: true),
      release('v99.0.0/other-repository'),
      release('v100.0.0-'),
      release('v101.0.0-..'),
      {'tag_name': 999},
      {'html_url': 'https://example.com'},
      null,
    ]);

    final result = await service.check('1.10.0');

    expect(result.latestVersion, '1.11.0-beta.10');
    expect(result.updateAvailable, isTrue);
  });

  test('a stable release wins over prereleases of the same core version',
      () async {
    final result = await serviceFor([
      release('v1.11.0-beta.10', prerelease: true),
      release('v1.11.0'),
      release('v1.11.0-rc.1', prerelease: true),
    ]).check('1.10.0');

    expect(result.latestVersion, '1.11.0');
  });

  test('version newer than published builds is treated as development',
      () async {
    final result = await serviceFor([
      release('v1.2.2', url: 'https://example.com/untrusted-release'),
    ]).check('1.3.0');

    expect(result.isLatest, isFalse);
    expect(result.updateAvailable, isFalse);
    expect(result.isDevelopmentVersion, isTrue);
    expect(result.releaseUri, UpdateCheckService.latestReleasePage);
    expect(result.releaseUri.toString(),
        'https://github.com/pandablin/Netcatty-mobile/releases');
  });

  test('foreign or mismatched release links fall back only to the fork page',
      () async {
    for (final url in [
      'https://github.com/another-owner/Netcatty-mobile/releases/tag/v2.0.0',
      'https://github.com/pandablin/another-repository/releases/tag/v2.0.0',
      'https://github.com/pandablin/Netcatty-mobile-other/releases/tag/v2.0.0',
      'https://github.com/pandablin/Netcatty-mobile/releases/tag/v1.0.0',
      'https://github.com/pandablin/Netcatty-mobile/releases/tag/v2.0.0/extra',
      'https://github.com/pandablin/Netcatty-mobile/releases/tag/v2.0.0?redirect=other',
      'https://github.com/pandablin/Netcatty-mobile/releases/tag/v2.0.0#other',
      'https://other@github.com/pandablin/Netcatty-mobile/releases/tag/v2.0.0',
      'https://github.com:444/pandablin/Netcatty-mobile/releases/tag/v2.0.0',
      'http://github.com/pandablin/Netcatty-mobile/releases/tag/v2.0.0',
      'https://github.com.example.com/pandablin/Netcatty-mobile/releases/tag/v2.0.0',
      'javascript:alert(1)',
      'not a URL',
    ]) {
      final result =
          await serviceFor([release('v2.0.0', url: url)]).check('1.0.0');
      expect(result.releaseUri, UpdateCheckService.latestReleasePage,
          reason: url);
      expect(result.updateAvailable, isTrue);
    }
  });

  test('empty or unusable release lists produce a readable error', () async {
    for (final releases in <List<Object?>>[
      [],
      [release('v9.0.0', draft: true)],
      [
        release('not-a-version'),
        {'html_url': 'https://example.com'},
        null
      ],
    ]) {
      await expectLater(
        serviceFor(releases).check('1.2.2'),
        throwsA(isA<UpdateCheckException>().having(
            (error) => error.message, 'message', contains('没有可用的 Release'))),
      );
    }
  });

  test('invalid JSON or the wrong API response shape produces a readable error',
      () async {
    for (final body in ['{', '{}', 'null', '"unexpected"']) {
      final service = UpdateCheckService(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        service.check('1.2.2'),
        throwsA(isA<UpdateCheckException>().having(
            (error) => error.message, 'message', contains('无法识别的版本信息'))),
      );
    }
  });

  test('HTTP failures retain their status and never fall back to upstream',
      () async {
    for (final status in [403, 404, 500]) {
      var requests = 0;
      final service = UpdateCheckService(client: MockClient((request) async {
        requests++;
        expect(request.url, UpdateCheckService.latestReleaseApi);
        return http.Response('{}', status);
      }));
      await expectLater(
        service.check('1.2.2'),
        throwsA(isA<UpdateCheckException>().having(
            (error) => error.message, 'message', contains('HTTP $status'))),
      );
      expect(requests, 1);
    }
  });

  test('network failure produces a retryable error', () async {
    final service = UpdateCheckService(
      client: MockClient((_) async {
        throw http.ClientException('connection aborted');
      }),
    );

    await expectLater(
      service.check('1.2.2'),
      throwsA(isA<UpdateCheckException>().having(
          (error) => error.message, 'message', contains('无法连接 GitHub'))),
    );
  });

  test('request timeout produces a readable error', () async {
    final service = UpdateCheckService(
      client:
          MockClient((_) async => throw TimeoutException('fixture timeout')),
    );

    await expectLater(
      service.check('1.2.2'),
      throwsA(isA<UpdateCheckException>()
          .having((error) => error.message, 'message', contains('检查更新超时'))),
    );
  });

  test('oversized chunked responses are stopped before decoding or buffering',
      () async {
    var cancelled = false;
    final stream = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    final service = UpdateCheckService(
      client: _StreamClient(stream.stream),
    );
    final assertion = expectLater(
      service.check('1.2.2'),
      throwsA(isA<UpdateCheckException>()
          .having((error) => error.message, 'message', contains('安全大小限制'))),
    );
    stream.add(List<int>.filled(UpdateCheckService.maxResponseBytes, 32));
    stream.add([32]);
    await assertion;
    expect(cancelled, isTrue);
    await stream.close();
  });

  test('closing the service preserves ownership of an injected HTTP client',
      () {
    final client = _StreamClient(const Stream.empty());
    UpdateCheckService(client: client).close();
    expect(client.closed, isFalse);
  });

  test('release version comparison follows semantic ordering', () {
    expect(compareReleaseVersions('v1.2.2', '1.2.2'), 0);
    expect(compareReleaseVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(compareReleaseVersions('2.0', '1.99.99'), greaterThan(0));
    expect(compareReleaseVersions('1.2.2', '1.2.2-beta.1'), greaterThan(0));
    expect(
        compareReleaseVersions('1.2.2-beta.2', '1.2.2-beta.10'), lessThan(0));
    expect(compareReleaseVersions('1.2.2+4', '1.2.2+30'), 0);
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.stream);
  final Stream<List<int>> stream;
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream, 200, request: request);

  @override
  void close() => closed = true;
}
