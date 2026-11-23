@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/application/auto_sync_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/sync/cloud_sync_service.dart';
import 'package:netcatty_mobile/infrastructure/sync/convergent_sync_adapter.dart';
import 'package:netcatty_mobile/infrastructure/sync/netcatty_crypto.dart';
import 'package:netcatty_mobile/infrastructure/sync/sync_safety.dart';
import 'package:netcatty_mobile/infrastructure/sync/vault_merge_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures/desktop_1_1_90_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secrets = <String, String>{};
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      final key = arguments['key']?.toString();
      switch (call.method) {
        case 'write':
          secrets[key!] = arguments['value'].toString();
          return null;
        case 'read':
          return secrets[key];
        case 'delete':
          secrets.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(secrets);
        case 'containsKey':
          return secrets.containsKey(key);
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<VaultRepository> repository() async {
    final repository = await VaultRepository.open();
    await repository.saveSyncConnection(const SyncConnection(
      type: SyncProviderType.webdav,
      endpoint: 'https://dav.example.invalid/nested/netcatty/',
      username: 'fixture',
      secret: 'fixture',
    ));
    await repository.saveMasterPassword('fixture-password');
    return repository;
  }

  CloudSyncService service(VaultRepository repository, MockClient client) =>
      CloudSyncService(repository,
          client: client, deviceId: 'phone-fixture', appVersion: 'test');

  test(
      'desktop 1.1.90 WebDAV data reaches UI state and survives repository reload',
      () async {
    final repo = await repository();
    final file = desktop1190EncryptedVault();
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.method, 'GET');
      expect(request.url.path, '/nested/netcatty/netcatty-vault.json');
      return http.Response(jsonEncode(file.toJson()), 200,
          headers: {'etag': '"fixture-5"'});
    });
    final vault = VaultController(repo);
    final sync = AutoSyncController(
      localChanges: repo.localChanges,
      loadVault: vault.ready,
      synchronize: service(repo, client).synchronize,
      applyVault: (value) => vault.replace(value, remote: true),
      retryDelays: const [],
    );
    addTearDown(sync.dispose);
    addTearDown(vault.dispose);

    final result = await sync.synchronizeNow();

    expect(requests, 1); // Fresh empty device adopts the cloud without writing.
    expect(vault.state.data!.hosts.single.id, 'desktop-host');
    expect(vault.state.data!.snippets.single.id, 'desktop-snippet');
    expect(vault.state.data!.keys.single.privateKey,
        'fixture-only-not-a-real-key');
    expect(result.message, contains('云端读取：1 台主机、1 条脚本、1 个密钥'));
    expect(result.message, contains('本机现有：1 台主机、1 条脚本、1 个密钥'));
    expect((await repo.loadSyncVersionCheckpoint())!.version, 5);

    final reopened = await VaultRepository.open();
    final restored = await reopened.loadVault();
    expect(restored.hosts.single.toJson(),
        desktop1190Vault().hosts.single.toJson());
    expect(restored.snippets.single.toJson(),
        desktop1190Vault().snippets.single.toJson());
    expect(restored.keys.single.privateKey, 'fixture-only-not-a-real-key');
    for (final field in ['monitorPanels', 'browserBookmarks']) {
      expect(restored.extras[field], desktop1190Vault().extras[field]);
    }
  });

  test(
      'missing WebDAV plus empty local never creates an empty cloud or reports success',
      () async {
    final repo = await repository();
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.method, 'GET');
      return http.Response('', 404);
    });
    await expectLater(
        service(repo, client).synchronize(VaultData.empty()),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('未上传空保险库'))));
    expect(requests, 1);
    expect(await repo.loadSyncVersionCheckpoint(), isNull);
    expect((await repo.loadVault()).hosts, isEmpty);
  });

  test('first WebDAV upload with real local data remains supported', () async {
    final repo = await repository();
    final files = <String, List<int>>{};
    var uploads = 0;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET') {
        final bytes = files[path];
        return bytes == null
            ? http.Response('', 404)
            : http.Response.bytes(bytes, 200);
      }
      if (request.method == 'PUT') {
        uploads++;
        files[path] = request.bodyBytes;
        return http.Response('', 201);
      }
      if (request.method == 'MOVE') {
        final destination = Uri.parse(request.headers['destination']!).path;
        files[destination] = files.remove(path)!;
        return http.Response('', 201);
      }
      fail('Unexpected fixture request: ${request.method}');
    });
    final local = VaultData.empty().copyWith(hosts: [
      HostProfile({'id': 'phone-host', 'label': 'Phone fixture'})
    ]);
    final result = await service(repo, client).synchronize(local);
    expect(uploads, 1);
    expect(result.vault.hosts.single.id, 'phone-host');
    expect(result.message, contains('首次上传完成'));
    final remote = SyncedVaultFile.fromJson(
        jsonDecode(utf8.decode(files['/nested/netcatty/netcatty-vault.json']!))
            as Map<String, dynamic>);
    expect(
        (await NetcattyCrypto.decrypt(remote, 'fixture-password'))
            .hosts
            .single
            .id,
        'phone-host');
  });

  test(
      'existing encrypted empty WebDAV file explicitly reports zero cloud content',
      () async {
    final repo = await repository();
    final file = await NetcattyCrypto.encrypt(
        vault: VaultData.empty(),
        password: 'fixture-password',
        deviceId: 'pc',
        deviceName: 'Fixture',
        appVersion: 'test');
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      return http.Response(jsonEncode(file.toJson()), 200);
    });
    final result = await service(repo, client).synchronize(VaultData.empty());
    expect(result.message, contains('云端保险库为空'));
    expect(result.message, contains('云端读取：0 台主机、0 条脚本、0 个密钥'));
  });

  for (final body in [
    '',
    '<html>not a vault</html>',
    '{}',
    '{"meta":{},"payload":"truncated"}'
  ]) {
    test(
        'malformed WebDAV body cannot apply, upload or acknowledge: ${body.length} bytes',
        () async {
      final repo = await repository();
      var writes = 0;
      final client = MockClient((request) async {
        if (request.method != 'GET') writes++;
        return http.Response(body, 200);
      });
      await expectLater(service(repo, client).synchronize(VaultData.empty()),
          throwsA(anything));
      expect(writes, 0);
      expect(await repo.loadSyncVersionCheckpoint(), isNull);
      expect((await repo.loadVault()).hosts, isEmpty);
    });
  }

  test('desktop-only v2 collections survive concurrent edits and causal join',
      () {
    final base = desktop1190Vault();
    validateConvergentSyncPayload(base);
    final phone = applyConvergentLocalChanges(
        replica: base,
        baseline: base,
        local: base.copyWith(hosts: [
          HostProfile({...base.hosts.single.toJson(), 'label': 'Phone edit'})
        ]),
        deviceId: 'phone-fixture',
        timestamp: 200);
    final desktop = applyConvergentLocalChanges(
        replica: base,
        baseline: base,
        local: base.copyWith(extras: {
          ...base.extras,
          'monitorPanels': [
            {
              'id': 'desktop-monitor',
              'name': 'Desktop edit',
              'hostIds': ['desktop-host']
            }
          ],
          'browserBookmarks': <dynamic>[],
        }),
        deviceId: 'desktop-fixture',
        timestamp: 300);
    final merged = mergeConvergentPayloads(phone, desktop);
    expect(merged.hosts.single.label, 'Phone edit');
    expect((merged.extras['monitorPanels'] as List).single['name'],
        'Desktop edit');
    expect(merged.extras['browserBookmarks'], isEmpty);
    expect(convergentPayloadDominates(merged, phone), isTrue);
    expect(convergentPayloadDominates(merged, desktop), isTrue);
    validateConvergentSyncPayload(merged);
  });

  test(
      'legacy merge, fingerprint and shrink guard include desktop-only collections',
      () {
    final base = desktop1190Vault();
    final legacy = VaultData.fromJson(base.toJson(legacySyncSnapshot: true));
    final adopted = mergeVaults(local: VaultData.empty(), remote: legacy);
    for (final field in ['monitorPanels', 'browserBookmarks']) {
      expect(adopted.extras[field], legacy.extras[field]);
      final many = legacy.copyWith(extras: {
        ...legacy.extras,
        field: List.generate(10, (i) => {'id': '$field-$i'})
      });
      final empty = many.copyWith(extras: {...many.extras, field: <dynamic>[]});
      expect(cloudSyncPayloadsEqual(many, empty), isFalse);
      expect(() => assertSafeSyncShrink(empty, many, many),
          throwsA(isA<SyncShrinkException>()));
      final deleted = mergeVaults(base: many, local: many, remote: empty);
      expect(deleted.extras[field], isEmpty);
    }
  });
}
