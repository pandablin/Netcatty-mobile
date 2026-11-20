import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_identity.dart';

/// Throwaway 1024-bit RSA key generated only for these tests, encrypted with
/// AES-256-CBC (legacy OpenSSL PEM) under the passphrase `netcatty-test`.
/// It is not authorised on any host.
const encryptedTestKey = '''
-----BEGIN RSA PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-256-CBC,CD0FD1AC0413B9AC37FC414B169A46CE

lWkNq5cCLTI3pFLhwQmcVTUze83opO4JB3OhSXgisHzjuLlvGtqgFQmuCUOCCrs8
xtPaY+hZ+8raVVaqJYfd4e9PDWnaWgcrO+Jg879549Tlajfhb2dndkAPeemtJz4e
CGiKNU++yHOGGAUyfRvJaKW2XeWoDzlTtogVzf1nwuG13LMtny/tqzGsIwQVvI31
fRQrm1sqEBUUHJWlz+8WCt7IQl0B4lBt0lEYGJCgetqowQdcl6ILlIdo/XCMDvf2
EfPbVtA+2fjSRPZ7KI1c2td/orTz79w/A7u26q9/V4ZWyoM7L3/ZmWHYB98rrUsC
DsfTRu8Hxwqy9cdrkhiM00Fmoig0rtv+/hW1sSeX1nRtD2nbgW7kvUGxNsl8wPuD
0Tl0ibdvqcqo9mCv3/H0Nwo3lYm/vlL3YyaOXa1NUPSQmQaCXbsEdsFBLNY3X28H
b6RFajdAbxVc9aZnK73Zw7mop2+jafMvvvE2RCmrCOe8UkiNxNd2aD7DpXlWfV9G
2EVttSHS+y9thGEzxwktOLB7A94SKwsm9jdkV4zolXYJ3zJ2b68f3RQ/xDu65Vdu
JvJn9Y05mgAwnQTAkw+RMU0PbtvtZBuHttwdPNnWwxYnrXWbqQHsRzBNHLJTdbsm
byztBt8VaJo0UkEzGp+iXoD9O62x/OzLMZ0f1u3l48smCH2mCG8eY1eL4HGQLI3f
kbC2Vyz2KAweYudUjIPuITI7EWFz7zPFCGxAYuSGjM8AvHSxqPeqe7NBXL2S4lmI
Mq2/MNBS93srlwEX2O2A6R8khhaePtYgzjszC4uIkydHN5ivWNixApxeqMWanoZw
-----END RSA PRIVATE KEY-----
''';

const testPassphrase = 'netcatty-test';

SshKeyProfile _key(Map<String, dynamic> data) => SshKeyProfile({
      'id': 'key-1',
      'label': 'encrypted test key',
      'privateKey': encryptedTestKey,
      ...data,
    });

HostProfile _host() => HostProfile({
      'id': 'host-1',
      'label': 'demo',
      'hostname': 'example.com',
      'username': 'demo',
      'authMethod': 'key',
      'identityFileId': 'key-1',
    });

void main() {
  group('normalizePrivateKeyText', () {
    test('normalises CRLF, BOM, indentation and literal escapes', () {
      const body = '-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----';
      expect(
        normalizePrivateKeyText(
          '\uFEFF  -----BEGIN RSA PRIVATE KEY-----\r\n  AAAA\r\n-----END RSA PRIVATE KEY-----\r\n',
        ),
        body,
      );
      expect(
        normalizePrivateKeyText(
          r'-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----',
        ),
        body,
      );
    });
  });

  group('loadHostIdentities', () {
    test('uses the stored passphrase without prompting', () async {
      var prompts = 0;
      final identities = await loadHostIdentities(
        _host(),
        [_key({'passphrase': testPassphrase})],
        requestPassphrase: (_, {required retry}) async {
          prompts++;
          return null;
        },
      );
      expect(identities, hasLength(1));
      expect(prompts, 0);
    });

    test('prompts when the passphrase is not stored and caches it', () async {
      final cache = <String, String>{};
      final retries = <bool>[];
      final identities = await loadHostIdentities(
        _host(),
        [_key({})],
        passphraseCache: cache,
        requestPassphrase: (_, {required retry}) async {
          retries.add(retry);
          return testPassphrase;
        },
      );
      expect(identities, hasLength(1));
      expect(retries, [false]);
      expect(cache['key-1'], testPassphrase);

      // A reconnect in the same app session reuses the cached passphrase.
      final again = await loadHostIdentities(
        _host(),
        [_key({})],
        passphraseCache: cache,
        requestPassphrase: (_, {required retry}) async =>
            fail('should not prompt again'),
      );
      expect(again, hasLength(1));
    });

    test('asks again after a wrong stored passphrase', () async {
      final retries = <bool>[];
      final identities = await loadHostIdentities(
        _host(),
        [_key({'passphrase': 'wrong'})],
        requestPassphrase: (_, {required retry}) async {
          retries.add(retry);
          return testPassphrase;
        },
      );
      expect(identities, hasLength(1));
      expect(retries, [true]);
    });

    test('reports a readable error when the prompt is cancelled', () {
      expect(
        loadHostIdentities(
          _host(),
          [_key({})],
          requestPassphrase: (_, {required retry}) async => null,
        ),
        throwsA(isA<SshKeyException>()),
      );
    });

    test('reports a readable error without a prompt handler', () {
      expect(
        loadHostIdentities(_host(), [_key({})]),
        throwsA(isA<SshKeyException>()),
      );
    });

    test('explains unsupported PKCS#8 keys', () {
      expect(
        loadHostIdentities(_host(), [
          _key({
            'privateKey':
                '-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----',
          }),
        ]),
        throwsA(isA<SshKeyException>()),
      );
    });
  });
}
