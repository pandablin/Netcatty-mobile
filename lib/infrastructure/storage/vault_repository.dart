import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models/host.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';
import 'background_image_service.dart';
import '../ai/ai_workspace.dart';

final vaultRepositoryProvider = Provider<VaultRepository>(
  (ref) => throw StateError('VaultRepository has not been initialized'),
);

enum VaultChangeOrigin { local, remote }

class VaultChange {
  const VaultChange(this.vault, this.origin);

  final VaultData vault;
  final VaultChangeOrigin origin;
}

class VaultRepository {
  VaultRepository._(
    this._preferences,
    this._secureStorage,
    this._backgroundImageService,
  );

  static const _vaultKey = 'netcatty_mobile_vault_v1';
  static const _settingsKey = 'netcatty_mobile_settings_v1';
  static const _syncKey = 'netcatty_mobile_sync_v1';
  static const _syncVersionKey = 'netcatty_mobile_sync_version_v1';
  static const _syncReplicaKey = 'netcatty_mobile_pending_sync_v2';
  static const _masterPasswordKey = 'netcatty.mobile.sync.masterPassword';
  static const _aiApiKey = 'netcatty.mobile.ai.apiKey';
  static const _deviceIdKey = 'netcatty_mobile_device_id_v1';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;
  final BackgroundImageService _backgroundImageService;
  final _changes = StreamController<VaultChange>.broadcast();
  late final aiWorkspace = AiWorkspace(
    read: (key) =>
        _secureStorage.read(key: 'netcatty.mobile.ai.workspace.$key'),
    write: (key, value) => value == null
        ? _secureStorage.delete(key: 'netcatty.mobile.ai.workspace.$key')
        : _secureStorage.write(
            key: 'netcatty.mobile.ai.workspace.$key', value: value),
  );
  VaultData? _cachedVault;
  Future<VaultData>? _vaultLoad;
  bool _vaultSecretsLoaded = false;

  /// Keychain contents of vault secrets (host./key./proxy. entries) as last
  /// read or written, or null while unknown. saveVault() uses it to skip
  /// unchanged values: it used to rewrite every secret of every host on each
  /// edit, hundreds of sequential keychain calls that made saves slow enough
  /// for a second edit to start from stale data and overwrite the first.
  Map<String, String>? _persistedSecrets;

  static bool _isVaultSecretKey(String key) =>
      key.startsWith('host.') ||
      key.startsWith('key.') ||
      key.startsWith('proxy.');

  static Future<VaultRepository> open({
    BackgroundImageService? backgroundImageService,
  }) async {
    final repository = VaultRepository._(
      await SharedPreferences.getInstance(),
      const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      ),
      backgroundImageService ?? BackgroundImageService(),
    );
    repository.loadVaultPreview();
    return repository;
  }

  Stream<VaultData> get changes => _changes.stream.map((event) => event.vault);

  /// Emits only user-originated mutations. Cloud sync listens to this stream
  /// so applying a downloaded vault never schedules an upload loop.
  Stream<VaultData> get localChanges => _changes.stream
      .where((event) => event.origin == VaultChangeOrigin.local)
      .map((event) => event.vault);

  /// Returns the non-secret part of the vault directly from the in-memory
  /// preferences snapshot. This lets list-oriented screens render without
  /// waiting for platform keychain calls.
  VaultData? loadVaultPreview() {
    if (_cachedVault != null) return _cachedVault;
    try {
      return _cachedVault = _readStoredVault();
    } on Object {
      return null;
    }
  }

  Future<VaultData> loadVault() {
    if (_vaultSecretsLoaded && _cachedVault != null) {
      return Future.value(_cachedVault);
    }
    final active = _vaultLoad;
    if (active != null) return active;
    final operation = _loadVaultWithSecrets();
    _vaultLoad = operation;
    return operation.whenComplete(() {
      if (identical(_vaultLoad, operation)) _vaultLoad = null;
    });
  }

  VaultData _readStoredVault() {
    final raw = _preferences.getString(_vaultKey);
    if (raw == null) return VaultData.empty();
    return VaultData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<VaultData> _loadVaultWithSecrets() async {
    final vault = _cachedVault ?? _readStoredVault();
    // One batched keychain query instead of one platform call per secret,
    // which made the first host tap noticeably slow on iOS.
    final all = await _readAllVaultSecrets();
    Future<String?> read(String key) {
      if (all != null) return Future.value(all[key]);
      return _secureStorage.read(key: key);
    }

    await Future.wait([
      ...vault.hosts.map((host) => _loadHostSecrets(host, read)),
      ...vault.keys.map((key) => _loadKeySecrets(key, read)),
      ...vault.proxyProfiles.map((profile) => _loadProxySecrets(profile, read)),
    ]);
    // A metadata-only edit (for example a snippet mutation) may complete while
    // platform keychain reads are still in flight. Keep that newer snapshot;
    // its host/key objects already received the hydrated secrets above.
    final latest = _cachedVault;
    final result = latest != null && !identical(latest, vault) ? latest : vault;
    _cachedVault = result;
    _vaultSecretsLoaded = true;
    return result;
  }

  Future<Map<String, String>?> _readAllVaultSecrets() async {
    try {
      final all = await _secureStorage.readAll();
      final secrets = <String, String>{
        for (final entry in all.entries)
          if (_isVaultSecretKey(entry.key)) entry.key: entry.value,
      };
      _persistedSecrets = Map.of(secrets);
      return secrets;
    } on Object {
      // Fall back to per-item reads; saves then write through as before.
      _persistedSecrets = null;
      return null;
    }
  }

  Future<void> _loadHostSecrets(
    HostProfile host,
    Future<String?> Function(String key) read,
  ) async {
    final values = await Future.wait([
      read('host.${host.id}.password'),
      read('host.${host.id}.telnetPassword'),
      read('host.${host.id}.proxyPassword'),
    ]);
    final password = values[0];
    final telnet = values[1];
    final proxyPassword = values[2];
    if (password != null) host.data['password'] = password;
    if (telnet != null) host.data['telnetPassword'] = telnet;
    if (proxyPassword != null && host.data['proxyConfig'] is Map) {
      host.data['proxyConfig'] = {
        ...Map<String, dynamic>.from(host.data['proxyConfig'] as Map),
        'password': proxyPassword,
      };
    }
  }

  Future<void> _loadKeySecrets(
    SshKeyProfile key,
    Future<String?> Function(String key) read,
  ) async {
    final values = await Future.wait([
      read('key.${key.id}.private'),
      read('key.${key.id}.passphrase'),
    ]);
    final privateKey = values[0];
    final passphrase = values[1];
    if (privateKey != null) key.data['privateKey'] = privateKey;
    if (passphrase != null) key.data['passphrase'] = passphrase;
  }

  Future<void> _loadProxySecrets(
    ProxyProfile profile,
    Future<String?> Function(String key) read,
  ) async {
    final password = await read('proxy.${profile.id}.password');
    if (password != null && profile.data['config'] is Map) {
      profile.data['config'] = {
        ...Map<String, dynamic>.from(profile.data['config'] as Map),
        'password': password,
      };
    }
  }

  Future<void> saveVault(VaultData vault, {bool remote = false}) async {
    final activeLoad = _vaultLoad;
    if (activeLoad != null) await activeLoad;
    final previousRaw = _preferences.getString(_vaultKey);
    if (previousRaw != null) {
      final previous = VaultData.fromJson(
        jsonDecode(previousRaw) as Map<String, dynamic>,
      );
      final hostIds = vault.hosts.map((value) => value.id).toSet();
      final keyIds = vault.keys.map((value) => value.id).toSet();
      final proxyIds = vault.proxyProfiles.map((value) => value.id).toSet();
      for (final host in previous.hosts.where(
        (value) => !hostIds.contains(value.id),
      )) {
        await _writeSecret('host.${host.id}.password', null);
        await _writeSecret('host.${host.id}.telnetPassword', null);
        await _writeSecret('host.${host.id}.proxyPassword', null);
      }
      for (final proxy in previous.proxyProfiles.where(
        (value) => !proxyIds.contains(value.id),
      )) {
        await _writeSecret('proxy.${proxy.id}.password', null);
      }
      for (final key in previous.keys.where(
        (value) => !keyIds.contains(value.id),
      )) {
        await _writeSecret('key.${key.id}.private', null);
        await _writeSecret('key.${key.id}.passphrase', null);
      }
    }
    for (final host in vault.hosts) {
      await _writeSecret('host.${host.id}.password', host.password);
      await _writeSecret(
        'host.${host.id}.telnetPassword',
        host.data['telnetPassword']?.toString(),
      );
      final proxy = host.proxyConfig;
      await _writeSecret('host.${host.id}.proxyPassword', proxy?.password);
    }
    for (final key in vault.keys) {
      await _writeSecret('key.${key.id}.private', key.privateKey);
      await _writeSecret('key.${key.id}.passphrase', key.passphrase);
    }
    for (final profile in vault.proxyProfiles) {
      final config = profile.config;
      await _writeSecret('proxy.${profile.id}.password', config?.password);
    }
    final sanitized = _withoutSecrets(vault);
    await _preferences.setString(_vaultKey, jsonEncode(sanitized.toJson()));
    _cachedVault = vault;
    _vaultSecretsLoaded = true;
    _changes.add(VaultChange(
      vault,
      remote ? VaultChangeOrigin.remote : VaultChangeOrigin.local,
    ));
  }

  /// Persists fields that never contain credentials without touching the
  /// platform keychain. This is intentionally limited to controller paths that
  /// only change snippets or other known non-secret metadata.
  Future<void> saveVaultMetadata(VaultData vault) async {
    final previousCache = _cachedVault;
    _cachedVault = vault;
    try {
      final sanitized = _withoutSecrets(vault);
      await _preferences.setString(_vaultKey, jsonEncode(sanitized.toJson()));
      _changes.add(VaultChange(vault, VaultChangeOrigin.local));
    } on Object {
      if (identical(_cachedVault, vault)) _cachedVault = previousCache;
      rethrow;
    }
  }

  VaultData _withoutSecrets(VaultData vault) {
    final sanitized = VaultData.fromJson(vault.toJson());
    for (final host in sanitized.hosts) {
      host.data.remove('password');
      host.data.remove('telnetPassword');
      if (host.data['proxyConfig'] is Map) {
        host.data['proxyConfig'] =
            Map<String, dynamic>.from(host.data['proxyConfig'] as Map)
              ..remove('password');
      }
    }
    for (final key in sanitized.keys) {
      key.data['privateKey'] = '';
      key.data.remove('passphrase');
    }
    for (final profile in sanitized.proxyProfiles) {
      if (profile.data['config'] is Map) {
        profile.data['config'] =
            Map<String, dynamic>.from(profile.data['config'] as Map)
              ..remove('password');
      }
    }
    return sanitized;
  }

  Future<AppSettings> loadSettings() async {
    final raw = _preferences.getString(_settingsKey);
    if (raw == null) return const AppSettings();
    final settings = AppSettings.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    String resolvedPath;
    try {
      resolvedPath = await _backgroundImageService.resolveStoredPath(
        settings.customBackgroundPath,
      );
    } on Object {
      return settings;
    }
    final resolved = resolvedPath == settings.customBackgroundPath
        ? settings
        : settings.copyWith(customBackgroundPath: resolvedPath);
    var portablePath = settings.customBackgroundPath;
    if (!portablePath.startsWith(BackgroundImageService.managedPathPrefix)) {
      try {
        portablePath = await _backgroundImageService.toStoredPath(resolvedPath);
      } on Object {
        return resolved;
      }
    }
    if (portablePath != settings.customBackgroundPath) {
      await _preferences.setString(
        _settingsKey,
        jsonEncode(
          resolved.copyWith(customBackgroundPath: portablePath).toJson(),
        ),
      );
    }
    return resolved;
  }

  Future<void> saveSettings(AppSettings settings) async {
    var portablePath = settings.customBackgroundPath;
    try {
      portablePath = await _backgroundImageService.toStoredPath(portablePath);
    } on Object {
      // Keep settings writable if the platform storage API is unavailable.
    }
    final persisted = settings.copyWith(customBackgroundPath: portablePath);
    await _preferences.setString(_settingsKey, jsonEncode(persisted.toJson()));
  }

  Future<SyncConnection?> loadSyncConnection() async {
    final raw = _preferences.getString(_syncKey);
    if (raw == null) return null;
    final connection = SyncConnection.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    final secret = await _secureStorage.read(key: 'sync.provider.secret');
    final sessionToken =
        await _secureStorage.read(key: 'sync.provider.sessionToken');
    return connection.copyWith(secret: secret, sessionToken: sessionToken);
  }

  Future<void> saveSyncConnection(SyncConnection connection) async {
    await _preferences.setString(_syncKey, jsonEncode(connection.toJson()));
    await _writeSecret('sync.provider.secret', connection.secret);
    await _writeSecret(
      'sync.provider.sessionToken',
      connection.sessionToken,
    );
  }

  Future<SyncVersionCheckpoint?> loadSyncVersionCheckpoint() async {
    final raw = _preferences.getString(_syncVersionKey);
    if (raw == null) return null;
    try {
      final checkpoint = SyncVersionCheckpoint.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return checkpoint.target.isEmpty ||
              checkpoint.version < 0 ||
              checkpoint.vaultFingerprint.isEmpty
          ? null
          : checkpoint;
    } on Object {
      return null;
    }
  }

  Future<void> saveSyncVersionCheckpoint(
    SyncVersionCheckpoint checkpoint,
  ) =>
      _preferences.setString(
        _syncVersionKey,
        jsonEncode(checkpoint.toJson()),
      );

  Future<void> clearSyncVersionCheckpoint() =>
      _preferences.remove(_syncVersionKey);

  // Contains only an encrypted replica/baseline bundle, never plaintext secrets.
  Future<Map<String, dynamic>?> loadPendingSyncReplica() async {
    final raw = _preferences.getString(_syncReplicaKey);
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> savePendingSyncReplica(Map<String, dynamic> value) =>
      _preferences.setString(_syncReplicaKey, jsonEncode(value));

  Future<void> clearPendingSyncReplica() =>
      _preferences.remove(_syncReplicaKey);

  Future<String?> readMasterPassword() =>
      _secureStorage.read(key: _masterPasswordKey);
  Future<void> saveMasterPassword(String? value) =>
      _writeSecret(_masterPasswordKey, value);
  Future<String?> readAiApiKey() => _secureStorage.read(key: _aiApiKey);
  Future<void> saveAiApiKey(String? value) => _writeSecret(_aiApiKey, value);

  Future<String> readOrCreateDeviceId() async {
    final existing = _preferences.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = const Uuid().v4();
    await _preferences.setString(_deviceIdKey, created);
    return created;
  }

  Future<void> _writeSecret(String key, String? value) async {
    final next = value == null || value.isEmpty ? null : value;
    final known = _isVaultSecretKey(key) ? _persistedSecrets : null;
    // A missing entry in a known snapshot means "not in the keychain".
    if (known != null && known[key] == next) return;
    if (next == null) {
      await _secureStorage.delete(key: key);
      known?.remove(key);
    } else {
      await _secureStorage.write(key: key, value: next);
      known?[key] = next;
    }
  }
}
