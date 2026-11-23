import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../domain/models/vault.dart';

class SyncedVaultFile {
  const SyncedVaultFile({required this.meta, required this.payload});

  factory SyncedVaultFile.fromJson(Map<String, dynamic> json) =>
      SyncedVaultFile(
        meta: Map<String, dynamic>.from(json['meta'] as Map),
        payload: json['payload'] as String,
      );

  final Map<String, dynamic> meta;
  final String payload;
  Map<String, dynamic> toJson() => {'meta': meta, 'payload': payload};
}

class NetcattyCrypto {
  static const iterations = 600000;
  // The work factor is outside the authenticated ciphertext. Bound it before
  // starting PBKDF2 so a corrupted/untrusted cloud file cannot pin a phone's
  // CPU indefinitely. Existing desktop/mobile files use 600,000 rounds.
  static const maxDecryptIterations = 2000000;
  static const saltLength = 32;
  static const ivLength = 12;
  static const tagLength = 16;

  /// Recently derived keys, by (password, salt, iterations). PBKDF2 with
  /// 600,000 rounds takes seconds in pure Dart on a phone, and one sync
  /// decrypts the same remote file several times (merge, read-back check,
  /// periodic checks while nothing changed). Memory only, a few entries.
  static final _keyCache = <(String, String, int), Uint8List>{};
  static const _keyCacheSize = 4;

  /// Derives (or reuses) the AES key on a background isolate so the UI keeps
  /// rendering while PBKDF2 runs.
  static Future<Uint8List> _deriveKey(
    String password,
    List<int> salt,
    int rounds,
  ) async {
    final cacheKey = (password, base64Encode(salt), rounds);
    final cached = _keyCache.remove(cacheKey);
    if (cached != null) {
      _keyCache[cacheKey] = cached;
      return cached;
    }
    final key = await Isolate.run(() async {
      final secret = await Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: rounds,
        bits: 256,
      ).deriveKeyFromPassword(password: password, nonce: salt);
      return Uint8List.fromList(await secret.extractBytes());
    });
    _keyCache[cacheKey] = key;
    while (_keyCache.length > _keyCacheSize) {
      _keyCache.remove(_keyCache.keys.first);
    }
    return key;
  }

  // Kept out of encrypt(): a closure there would put the Random object into
  // the context that the isolate closure captures and sends.
  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static Future<SyncedVaultFile> encrypt({
    required VaultData vault,
    required String password,
    required String deviceId,
    required String deviceName,
    required String appVersion,
    int previousVersion = 0,
  }) async {
    final salt = _randomBytes(saltLength);
    final iv = _randomBytes(ivLength);
    final key = await _deriveKey(password, salt, iterations);
    final convergent = vault.extras['convergentSync'];
    final isConvergentV2 = convergent is Map &&
        convergent['schemaVersion'] == 2 &&
        convergent['encoding'] == 'materialized-winner-v1';
    // Serialising and encrypting a multi-megabyte vault also runs off the UI
    // isolate.
    final payload = await Isolate.run(() async {
      // Legacy writes remain v1. When the remote already uses desktop's
      // convergent format, the caller supplies an updated envelope and we
      // must preserve it together with the advertised plaintext schema
      // version.
      final cleartext = utf8.encode(jsonEncode(vault.toJson(
        legacySyncSnapshot: !isConvergentV2,
      )));
      final box = await AesGcm.with256bits().encrypt(
        cleartext,
        secretKey: SecretKey(key),
        nonce: iv,
      );
      return base64Encode([...box.cipherText, ...box.mac.bytes]);
    });
    return SyncedVaultFile(
      meta: {
        'version': previousVersion + 1,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'appVersion': appVersion,
        'iv': base64Encode(iv),
        'salt': base64Encode(salt),
        'algorithm': 'AES-256-GCM',
        'kdf': 'PBKDF2',
        'kdfIterations': iterations,
        if (isConvergentV2) 'syncSchemaVersion': 2,
      },
      payload: payload,
    );
  }

  static Future<VaultData> decrypt(
    SyncedVaultFile file,
    String password,
  ) async {
    if (file.meta['algorithm'] != 'AES-256-GCM' ||
        file.meta['kdf'] != 'PBKDF2') {
      throw const FormatException('Unsupported Netcatty encryption format');
    }
    final rawRounds = file.meta['kdfIterations'];
    if (rawRounds != null &&
        (rawRounds is! int ||
            rawRounds < 1 ||
            rawRounds > maxDecryptIterations)) {
      throw const FormatException('同步文件的密钥推导次数无效或超出安全限制');
    }
    final rounds = rawRounds as int? ?? iterations;
    final saltValue = file.meta['salt'];
    final ivValue = file.meta['iv'];
    if (saltValue is! String || ivValue is! String) {
      throw const FormatException('同步文件缺少有效的 salt 或 IV');
    }
    final salt = base64Decode(saltValue);
    final iv = base64Decode(ivValue);
    if (salt.length != saltLength || iv.length != ivLength) {
      throw const FormatException('同步文件的 salt 或 IV 长度无效');
    }
    final payload = file.payload;
    final body = base64Decode(payload);
    if (body.length <= tagLength) {
      throw const FormatException('Encrypted payload is truncated');
    }
    final key = await _deriveKey(password, salt, rounds);
    return Isolate.run(() async {
      final box = SecretBox(
        body.sublist(0, body.length - tagLength),
        nonce: iv,
        mac: Mac(body.sublist(body.length - tagLength)),
      );
      try {
        final cleartext = await AesGcm.with256bits().decrypt(
          box,
          secretKey: SecretKey(key),
        );
        return VaultData.fromJson(
          jsonDecode(utf8.decode(cleartext)) as Map<String, dynamic>,
        );
      } on SecretBoxAuthenticationError {
        throw const FormatException('同步密码错误或云端文件已损坏');
      }
    });
  }
}
