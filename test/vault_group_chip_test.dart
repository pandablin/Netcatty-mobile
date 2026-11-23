import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/screens/vault_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('vault group labels are centered inside a stable chip area',
      (tester) async {
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
    });
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_vault_v1': jsonEncode({
        'hosts': [
          {
            'id': 'host-1',
            'label': 'Server',
            'hostname': '192.0.2.10',
            'username': 'root',
            'group': '生产',
          },
        ],
        'keys': const [],
        'snippets': const [],
        'customGroups': ['生产'],
      }),
    });
    final repository = await VaultRepository.open();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          home: Scaffold(body: VaultScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('vault-group-chip-all'));
    final label = find.text('全部');
    expect(chip, findsOneWidget);
    expect(label, findsOneWidget);
    final chipCenter = tester.getCenter(chip);
    final labelCenter = tester.getCenter(label);
    expect((chipCenter.dx - labelCenter.dx).abs(), lessThan(1));
    expect((chipCenter.dy - labelCenter.dy).abs(), lessThan(1));
    expect(tester.getSize(chip).height, 36);
  });

  testWidgets('long press opens a context menu that copies the IP',
      (tester) async {
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    String? copied;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(secureStorageChannel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_vault_v1': jsonEncode({
        'hosts': [
          {
            'id': 'host-1',
            'label': 'Server',
            'hostname': '192.0.2.10',
            'username': 'root',
          },
        ],
        'keys': const [],
        'snippets': const [],
      }),
    });
    final repository = await VaultRepository.open();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          home: Scaffold(body: VaultScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Server').first);
    await tester.pumpAndSettle();
    // iOS-style context menu with the actions and a lifted preview.
    expect(find.text('查看详情'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('root@192.0.2.10:22'), findsWidgets);

    await tester.tap(find.text('复制 IP'));
    await tester.pumpAndSettle();
    expect(copied, '192.0.2.10');
    expect(find.text('查看详情'), findsNothing);
    expect(find.text('已复制 IP'), findsOneWidget);
  });
}
