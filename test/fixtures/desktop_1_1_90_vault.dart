import 'dart:convert';
import 'dart:io';

import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/sync/netcatty_crypto.dart';

// Generated using the installed desktop 1.1.90 bundle's dtt/REe/JEe functions.
// All entities, commands and credentials are synthetic; password: fixture-password.
VaultData desktop1190Vault() => VaultData.fromJson(
      jsonDecode(
              File('test/fixtures/desktop_1_1_90_v2.json').readAsStringSync())
          as Map<String, dynamic>,
    );

SyncedVaultFile desktop1190EncryptedVault() => SyncedVaultFile.fromJson(
      jsonDecode(
        File('test/fixtures/desktop_1_1_90_v2_encrypted.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>,
    );
