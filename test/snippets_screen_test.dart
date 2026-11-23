import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:netcatty_mobile/presentation/screens/snippets_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => NetcattyLocalizations.use('zh-CN'));

  Future<VaultRepository> showSnippets(
      WidgetTester tester, Map<String, dynamic> value) async {
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_vault_v1': jsonEncode({
        'hosts': const [],
        'keys': const [],
        'customGroups': const [],
        ...value,
      }),
    });
    final repository = await VaultRepository.open();
    await tester.pumpWidget(ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: const MaterialApp(home: SnippetsScreen()),
    ));
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets(
      'desktop groups start collapsed and expanding reveals only that group',
      (tester) async {
    await showSnippets(tester, {
      'snippetPackages': ['Tools', 'Ops', 'Empty'],
      'snippets': [
        {
          'id': 'a',
          'label': 'Only A',
          'command': 'printf A',
          'package': 'Tools'
        },
        {'id': 'b', 'label': 'Only B', 'command': 'printf B', 'package': 'Ops'},
        {'id': 'c', 'label': 'Only C', 'command': 'printf C'},
      ],
    });
    for (final group in ['Tools', 'Ops', 'Empty', '未分组']) {
      expect(find.text(group), findsOneWidget);
    }
    expect(find.text('Only A'), findsNothing);
    expect(find.text('Only B'), findsNothing);
    expect(find.text('Only C'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('snippet-group-Tools')));
    await tester.pumpAndSettle();
    expect(find.text('Only A'), findsOneWidget);
    expect(find.text('Only B'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('snippet-group-Ops')));
    await tester.pumpAndSettle();
    expect(find.text('Only A'), findsNothing);
    expect(find.text('Only B'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('snippet-group-Ops')));
    await tester.pumpAndSettle();
    expect(find.text('Only B'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('snippet-group-Empty')));
    await tester.pumpAndSettle();
    expect(find.text('该分组暂无片段'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('snippet-group-')));
    await tester.pumpAndSettle();
    expect(find.text('Only C'), findsOneWidget);
  });

  testWidgets('declared empty desktop groups remain visible without snippets',
      (tester) async {
    await showSnippets(tester, {
      'snippetPackages': ['Empty'],
      'snippets': const [],
    });
    expect(find.text('Empty'), findsOneWidget);
    expect(find.text('还没有命令片段'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('snippet-group-Empty')));
    await tester.pumpAndSettle();
    expect(find.text('该分组暂无片段'), findsOneWidget);
  });

  testWidgets(
      'editing a group preserves desktop script metadata and command bytes',
      (tester) async {
    const command = 'printf first\r\nprintf second\n';
    final repository = await showSnippets(tester, {
      'snippetPackages': ['Tools', 'Ops'],
      'snippets': [
        {
          'id': 'a',
          'label': 'Fixture script',
          'command': command,
          'package': 'Tools',
          'kind': 'script',
          'language': 'javascript',
          'tags': ['fixture'],
          'scriptOptions': {'future': true},
          'noAutoRun': true,
        }
      ],
    });
    await tester.tap(find.byKey(const ValueKey('snippet-group-Tools')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('snippet-actions-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('snippet-choose-package')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ops').last);
    await tester.pumpAndSettle();
    final packageField = tester
        .widget<TextField>(find.byKey(const ValueKey('snippet-edit-package')));
    expect(packageField.controller!.text, 'Ops');
    await tester.ensureVisible(find.byKey(const ValueKey('save-snippet')));
    await tester.tap(find.byKey(const ValueKey('save-snippet')));
    await tester.pumpAndSettle();
    final updated = (await repository.loadVault()).snippets.single;
    expect(updated.data['package'], 'Ops');
    expect(updated.command, command);
    expect(updated.data['kind'], 'script');
    expect(updated.data['language'], 'javascript');
    expect(updated.data['scriptOptions'], {'future': true});
    expect(updated.data['tags'], ['fixture']);
    expect(updated.autoRun, isFalse);
    expect((await repository.loadVault()).extras['snippetPackages'],
        ['Tools', 'Ops']);
  });

  testWidgets(
      'creating a snippet adds the new package to desktop sync metadata',
      (tester) async {
    final repository = await showSnippets(tester, {'snippets': const []});
    await tester.tap(find.text('新建片段'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('snippet-edit-label')), 'New command');
    await tester.enterText(
        find.byKey(const ValueKey('snippet-edit-package')), '  New group  ');
    await tester.enterText(
        find.byKey(const ValueKey('snippet-edit-command')), 'printf fixture');
    await tester.ensureVisible(find.byKey(const ValueKey('save-snippet')));
    await tester.tap(find.byKey(const ValueKey('save-snippet')));
    await tester.pumpAndSettle();
    final updated = await repository.loadVault();
    expect(updated.snippets.single.data['package'], 'New group');
    expect(updated.extras['snippetPackages'], ['New group']);
    expect(find.text('New group'), findsOneWidget);
    expect(find.text('New command'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('snippet-group-New group')));
    await tester.pumpAndSettle();
    expect(find.text('New command'), findsOneWidget);
  });

  testWidgets('snippet can be deleted after confirmation', (tester) async {
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_vault_v1': jsonEncode({
        'hosts': const [],
        'keys': const [],
        'snippets': [
          {
            'id': 'snippet-1',
            'label': 'Disk usage',
            'command': 'df -h',
          },
        ],
        'customGroups': const [],
      }),
    });
    final repository = await VaultRepository.open();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: SnippetsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('snippet-group-')));
    await tester.pumpAndSettle();
    expect(find.text('Disk usage'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('snippet-actions-snippet-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-snippet-snippet-1')));
    await tester.pumpAndSettle();

    expect(find.text('删除命令片段？'), findsOneWidget);
    expect(
      find.text('将删除“Disk usage”，此操作可通过云同步传播到其他设备。'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-delete-snippet')));
    await tester.pumpAndSettle();

    expect(find.text('Disk usage'), findsNothing);
    expect(find.text('还没有命令片段'), findsOneWidget);
    expect((await repository.loadVault()).snippets, isEmpty);
  });
}
