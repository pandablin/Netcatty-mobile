import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/application/home_navigation.dart';
import 'package:netcatty_mobile/infrastructure/http_client_provider.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/home_shell.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProviderContainer> showSettings(
    WidgetTester tester, {
    required VoidCallback onSystemExit,
    Widget Function(Widget child)? wrapHome,
  }) async {
    SharedPreferences.setMockInitialValues({});
    NetcattyLocalizations.use('zh-CN');
    PackageInfo.setMockInitialValues(
      appName: 'Netcatty',
      packageName: 'app.netcatty.mobile.audit',
      version: '1.10.0',
      buildNumber: '48',
      buildSignature: 'fixture',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const storage =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    messenger.setMockMethodCallHandler(storage, (_) async => null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') onSystemExit();
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(storage, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final repository = await VaultRepository.open();
    final client = MockClient((request) async => http.Response(
          jsonEncode({
            'tag_name': 'v1.10.0',
            'html_url':
                'https://github.com/wxte/Netcatty-mobile/releases/tag/v1.10.0',
            'draft': false,
            'prerelease': false,
          }),
          200,
        ));
    final container = ProviderContainer(overrides: [
      vaultRepositoryProvider.overrideWithValue(repository),
      httpClientProvider.overrideWithValue(client),
      homeTabProvider.overrideWith((ref) => 4),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      client.close();
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: wrapHome?.call(const HomeShell()) ?? const HomeShell(),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
      'Android system back returns from a settings section to its index',
      (tester) async {
    var systemExits = 0;
    await showSettings(tester, onSystemExit: () => systemExits++);
    await tester.tap(find.byKey(const ValueKey('settings-terminal')));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(systemExits, 0);
    expect(find.byType(BackButton), findsNothing);
    expect(find.byKey(const ValueKey('settings-terminal')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings index leaves Android back to the app root',
      (tester) async {
    var systemExits = 0;
    await showSettings(tester, onSystemExit: () => systemExits++);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(systemExits, 1);
    expect(find.byKey(const ValueKey('settings-terminal')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a hidden settings section does not consume terminal tab back',
      (tester) async {
    var systemExits = 0;
    final container =
        await showSettings(tester, onSystemExit: () => systemExits++);
    await tester.tap(find.byKey(const ValueKey('settings-terminal')));
    await tester.pumpAndSettle();
    container.read(homeTabProvider.notifier).state = 1;
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(systemExits, 1);
    expect(container.read(homeTabProvider), 1);
    container.read(homeTabProvider.notifier).state = 4;
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings toolbar back keeps the nested navigation working',
      (tester) async {
    var systemExits = 0;
    await showSettings(tester, onSystemExit: () => systemExits++);
    await tester.tap(find.byKey(const ValueKey('settings-appearance')));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(systemExits, 0);
    expect(find.byType(BackButton), findsNothing);
    expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('another back handler cannot pop an inactive settings section',
      (tester) async {
    var systemExits = 0;
    var handledBack = 0;
    final container = await showSettings(
      tester,
      onSystemExit: () => systemExits++,
      wrapHome: (child) => PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) handledBack++;
        },
        child: child,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('settings-terminal')));
    await tester.pumpAndSettle();
    container.read(homeTabProvider.notifier).state = 1;
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handledBack, 1);
    expect(systemExits, 0);
    expect(container.read(homeTabProvider), 1);
    container.read(homeTabProvider.notifier).state = 4;
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
