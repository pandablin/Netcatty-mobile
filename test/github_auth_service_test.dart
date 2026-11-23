import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/infrastructure/sync/github_auth_service.dart';

void main() {
  const ownerClientId = 'fixture-owner-oauth-app';
  GitHubDeviceAuthorization authorization() => GitHubDeviceAuthorization(
        deviceCode: 'device-code',
        userCode: 'ABCD-1234',
        verificationUri: Uri.parse('https://github.com/login/device'),
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
        interval: Duration.zero,
      );

  test('production client ID comes only from the compile-time owner setting',
      () {
    expect(GitHubAuthService.clientId,
        const String.fromEnvironment('GITHUB_OAUTH_CLIENT_ID'));
  });

  test('default constructor uses the compiled owner ID or stops before network',
      () async {
    var requests = 0;
    final configuredId = GitHubAuthService.clientId.trim();
    final service = GitHubAuthService(client: MockClient((request) async {
      requests++;
      expect(Uri.splitQueryString(request.body)['client_id'], configuredId);
      expect(configuredId, isNotEmpty);
      return http.Response(
          jsonEncode({
            'device_code': 'fixture-device-code',
            'user_code': 'FIXT-URE1',
            'verification_uri': 'https://github.com/login/device',
            'expires_in': 600,
          }),
          200);
    }));
    if (configuredId.isEmpty) {
      await expectLater(service.start(), throwsStateError);
      expect(requests, 0);
    } else {
      expect((await service.start()).deviceCode, 'fixture-device-code');
      expect(requests, 1);
    }
  });

  test('device authorization uses the configured owner app and original scopes',
      () async {
    var requests = 0;
    final service = GitHubAuthService(
      oauthClientId: '  $ownerClientId  ',
      client: MockClient((request) async {
        requests++;
        expect(request.url.toString(), 'https://github.com/login/device/code');
        expect(Uri.splitQueryString(request.body), {
          'client_id': ownerClientId,
          'scope': 'gist read:user',
        });
        return http.Response(
            jsonEncode({
              'device_code': 'fixture-device-code',
              'user_code': 'FIXT-URE1',
              'verification_uri': 'https://github.com/login/device',
              'expires_in': 600,
              'interval': 5,
            }),
            200);
      }),
    );
    final started = await service.start();
    expect(requests, 1);
    expect(started.deviceCode, 'fixture-device-code');
    expect(started.userCode, 'FIXT-URE1');
    expect(started.interval, const Duration(seconds: 5));
  });

  for (final blankId in ['', ' \t\n ']) {
    test(
        'unconfigured app refuses start and poll before any delay or network (${blankId.length})',
        () async {
      var requests = 0;
      var delays = 0;
      final states = <GitHubAuthPollState>[];
      final service = GitHubAuthService(
        oauthClientId: blankId,
        client: MockClient((request) async {
          requests++;
          return http.Response('{}', 200);
        }),
        delay: (_) async {
          delays++;
        },
      );
      final configurationError = isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('未配置 GitHub OAuth Client ID'));
      await expectLater(service.start(), throwsA(configurationError));
      await expectLater(
          service.poll(authorization(), onStateChanged: states.add),
          throwsA(configurationError));
      expect(requests, 0);
      expect(delays, 0);
      expect(states, isEmpty);
    });
  }

  test('already cancelled poll remains cancellable without an OAuth app',
      () async {
    var requests = 0;
    final service = GitHubAuthService(
      oauthClientId: '',
      client: MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      }),
      delay: (_) async {},
    );
    await expectLater(service.poll(authorization(), isCancelled: () => true),
        throwsA(isA<GitHubAuthCancelledException>()));
    expect(requests, 0);
  });

  test('cancelling during the polling delay prevents its next network request',
      () async {
    var cancelled = false;
    var requests = 0;
    final service = GitHubAuthService(
      oauthClientId: ownerClientId,
      client: MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      }),
      delay: (_) async {
        cancelled = true;
      },
    );
    await expectLater(
        service.poll(authorization(), isCancelled: () => cancelled),
        throwsA(isA<GitHubAuthCancelledException>()));
    expect(requests, 0);
  });

  test('cancellation while a response is in flight never returns its token',
      () async {
    var cancelled = false;
    final requested = Completer<void>();
    final response = Completer<http.Response>();
    final service = GitHubAuthService(
      oauthClientId: ownerClientId,
      client: MockClient((request) async {
        requested.complete();
        return response.future;
      }),
      delay: (_) async {},
    );
    final pending = service.poll(authorization(), isCancelled: () => cancelled);
    await requested.future;
    cancelled = true;
    final assertion =
        expectLater(pending, throwsA(isA<GitHubAuthCancelledException>()));
    response.complete(
        http.Response(jsonEncode({'access_token': 'fixture-token'}), 200));
    await assertion;
  });

  test('device polling recovers from an aborted mobile connection', () async {
    var requests = 0;
    final states = <GitHubAuthPollState>[];
    final client = MockClient((request) async {
      requests++;
      expect(request.url.toString(),
          'https://github.com/login/oauth/access_token');
      expect(Uri.splitQueryString(request.body), {
        'client_id': ownerClientId,
        'device_code': 'device-code',
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      if (requests == 1) {
        throw http.ClientException('Software caused connection abort');
      }
      if (requests == 2) {
        return http.Response(
          jsonEncode({'error': 'authorization_pending'}),
          200,
        );
      }
      return http.Response(jsonEncode({'access_token': 'token-123'}), 200);
    });
    final service = GitHubAuthService(
      oauthClientId: ownerClientId,
      client: client,
      delay: (_) async {},
    );

    final token = await service.poll(
      authorization(),
      onStateChanged: states.add,
    );

    expect(token, 'token-123');
    expect(requests, 3);
    expect(states, contains(GitHubAuthPollState.retryingNetwork));
    expect(states.last, GitHubAuthPollState.waitingForAuthorization);
  });

  test('closing the login dialog cancels polling before a request', () async {
    var requests = 0;
    final service = GitHubAuthService(
      oauthClientId: ownerClientId,
      client: MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      }),
      delay: (_) async {},
    );

    await expectLater(
      service.poll(authorization(), isCancelled: () => true),
      throwsA(isA<GitHubAuthCancelledException>()),
    );
    expect(requests, 0);
  });

  test('user lookup retries a transient connection abort', () async {
    var requests = 0;
    final service = GitHubAuthService(
      oauthClientId: '', // Existing tokens do not require an OAuth app setting.
      client: MockClient((request) async {
        requests++;
        expect(request.headers['authorization'], 'Bearer token-123');
        expect(request.url.toString(), 'https://api.github.com/user');
        if (requests == 1) {
          throw http.ClientException('Software caused connection abort');
        }
        return http.Response(jsonEncode({'login': 'netcatty-user'}), 200);
      }),
      delay: (_) async {},
    );

    final user = await service.currentUser('token-123');

    expect(user['login'], 'netcatty-user');
    expect(requests, 2);
  });
}
