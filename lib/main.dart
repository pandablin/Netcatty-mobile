import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'infrastructure/storage/vault_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(_fontLicenses);
  final repository = await VaultRepository.open();
  runApp(
    ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: const NetcattyApp(),
    ),
  );
}

/// SIL OFL notices for the bundled interface fonts.
Stream<LicenseEntry> _fontLicenses() async* {
  for (final (font, file) in const [
    ('DM Sans', 'assets/fonts/OFL-DMSans.txt'),
    ('Lora', 'assets/fonts/OFL-Lora.txt'),
  ]) {
    yield LicenseEntryWithLineBreaks([font], await rootBundle.loadString(file));
  }
}
