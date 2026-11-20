import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';

import '../../domain/models/host.dart';

/// Builds the client identities for [host] from the vault [keys].
///
/// Returns null when the host does not reference a usable private key, so the
/// caller can fall back to password authentication.
List<SSHKeyPair>? buildHostIdentities(
    HostProfile host, List<SshKeyProfile> keys) {
  final identity = keys.cast<SshKeyProfile?>().firstWhere(
        (value) => value?.id == host.identityFileId,
        orElse: () => null,
      );
  if (identity == null || identity.privateKey.isEmpty) return null;
  return SSHKeyPair.fromPem(
      identity.privateKey, normalizedPassphrase(identity));
}

/// Returns the key passphrase, or null when the key is not protected.
///
/// dartssh2 rejects any passphrase argument for an unencrypted key, so an empty
/// or whitespace-only stored value has to become null instead of `''`. The key
/// picker stores `''` when the user leaves the optional passphrase field empty,
/// and that value is also already persisted in existing vaults.
///
/// Whitespace-only values are treated as empty. A passphrase made only of
/// spaces cannot be entered reliably on a mobile keyboard, while a passphrase
/// that merely starts or ends with whitespace is preserved untouched.
String? normalizedPassphrase(SshKeyProfile key) {
  final passphrase = key.passphrase;
  if (passphrase == null) return null;
  return passphrase.trim().isEmpty ? null : passphrase;
}

/// Guesses the key type label from a PEM/OpenSSH private key body.
///
/// Returns null when the format is not recognised, so the caller can fall back
/// to a generic label. This is only used for display.
String? detectPrivateKeyType(String privateKey) {
  if (privateKey.contains('BEGIN OPENSSH PRIVATE KEY')) return 'OpenSSH';
  if (privateKey.contains('BEGIN RSA PRIVATE KEY')) return 'RSA';
  if (privateKey.contains('BEGIN EC PRIVATE KEY')) return 'ECDSA';
  if (privateKey.contains('BEGIN DSA PRIVATE KEY')) return 'DSA';
  if (privateKey.contains('BEGIN PRIVATE KEY')) return 'PKCS#8';
  return null;
}

/// Asks the user for the passphrase of [key]. [retry] is true when a previous
/// passphrase (stored or typed) was rejected. Returns null when the user
/// cancels.
typedef KeyPassphraseHandler = Future<String?> Function(
  SshKeyProfile key, {
  required bool retry,
});

/// A private key problem the user can act on, with a readable message.
class SshKeyException implements Exception {
  const SshKeyException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Cleans up private key text pasted or synced from other devices: strips a
/// UTF-8 BOM, normalises CRLF/CR line endings, expands literal `\n` escapes
/// (seen when a key was copied out of JSON) and trims surrounding whitespace.
String normalizePrivateKeyText(String text) {
  var value = text.replaceFirst('\uFEFF', '');
  if (!value.contains('\n') && value.contains(r'\n')) {
    value = value.replaceAll(r'\r\n', '\n').replaceAll(r'\n', '\n');
  }
  value = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return value.split('\n').map((line) => line.trim()).join('\n').trim();
}

/// Rejects key formats dartssh2 cannot read with a message that says how to
/// convert them, instead of a bare "Unsupported key type".
void _ensureSupportedKeyFormat(String pem) {
  if (pem.startsWith('PuTTY-User-Key-File')) {
    throw const SshKeyException(
      '暂不支持 PuTTY 私钥（.ppk），请用 PuTTYgen 导出为 OpenSSH 格式后重新导入',
    );
  }
  if (pem.contains('BEGIN ENCRYPTED PRIVATE KEY') ||
      pem.contains('BEGIN PRIVATE KEY')) {
    throw const SshKeyException(
      '暂不支持 PKCS#8 私钥，请执行 ssh-keygen -p -f <私钥文件> 转换为 OpenSSH 格式后重新导入',
    );
  }
  if (!pem.contains('PRIVATE KEY-----')) {
    throw const SshKeyException('私钥内容无法识别，请重新导入私钥文件');
  }
}

/// Resolves the client identities for [host], asking for the passphrase of an
/// encrypted key through [requestPassphrase] when none is stored or the stored
/// one is wrong.
///
/// [passphraseCache] keeps passphrases the user typed in memory (never on
/// disk) so reconnects and extra tabs in the same app session don't ask again.
///
/// Decrypting an OpenSSH key runs bcrypt_pbkdf, which takes seconds in pure
/// Dart on a phone, so encrypted keys are decoded on a background isolate to
/// keep the UI responsive.
Future<List<SSHKeyPair>?> loadHostIdentities(
  HostProfile host,
  List<SshKeyProfile> keys, {
  KeyPassphraseHandler? requestPassphrase,
  Map<String, String>? passphraseCache,
}) async {
  final identity = keys.cast<SshKeyProfile?>().firstWhere(
        (value) => value?.id == host.identityFileId,
        orElse: () => null,
      );
  if (identity == null || identity.privateKey.trim().isEmpty) return null;
  final pem = normalizePrivateKeyText(identity.privateKey);
  _ensureSupportedKeyFormat(pem);

  if (!_isEncryptedKey(pem)) {
    try {
      return SSHKeyPair.fromPem(pem);
    } on Object catch (error) {
      throw SshKeyException('私钥解析失败：$error');
    }
  }

  var passphrase =
      passphraseCache?[identity.id] ?? normalizedPassphrase(identity);
  var retry = false;
  for (var attempt = 0; attempt < 5; attempt++) {
    if (passphrase == null) {
      if (requestPassphrase == null) {
        throw const SshKeyException('该私钥已加密，请在密钥设置中填写口令');
      }
      passphrase = await requestPassphrase(identity, retry: retry);
      if (passphrase == null) {
        throw const SshKeyException('已取消输入私钥口令');
      }
    }
    final result = await decodeEncryptedKeyInBackground(pem, passphrase);
    if (result.pairs != null) {
      passphraseCache?[identity.id] = passphrase;
      return result.pairs;
    }
    if (!result.wrongPassphrase) {
      throw SshKeyException('私钥解析失败：${result.error}');
    }
    passphraseCache?.remove(identity.id);
    passphrase = null;
    retry = true;
  }
  throw const SshKeyException('私钥口令错误次数过多');
}

bool _isEncryptedKey(String pem) {
  try {
    return SSHKeyPair.isEncryptedPem(pem);
  } on Object catch (error) {
    throw SshKeyException('私钥格式无法识别：$error');
  }
}

/// Decodes an encrypted key off the UI isolate. Errors are returned rather
/// than thrown so their type survives the isolate boundary.
Future<({List<SSHKeyPair>? pairs, bool wrongPassphrase, String? error})>
    decodeEncryptedKeyInBackground(String pem, String passphrase) {
  return Isolate.run(() {
    try {
      return (
        pairs: SSHKeyPair.fromPem(pem, passphrase),
        wrongPassphrase: false,
        error: null,
      );
    } on SSHKeyDecodeError catch (error) {
      // Covers SSHKeyDecryptError (OpenSSH check-int mismatch) and the
      // garbage ASN.1 a wrong passphrase produces for legacy PEM keys.
      return (pairs: null, wrongPassphrase: true, error: error.toString());
    } on Object catch (error) {
      return (pairs: null, wrongPassphrase: false, error: error.toString());
    }
  });
}
