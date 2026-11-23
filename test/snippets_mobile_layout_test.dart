import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:netcatty_mobile/presentation/screens/snippets_screen.dart';
import 'package:netcatty_mobile/presentation/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      '430px mobile groups and editor fit with a visible keyboard inset',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    NetcattyLocalizations.use('zh-CN');
    const previewDir = String.fromEnvironment('SNIPPET_PREVIEW_DIR');
    const previewFont = String.fromEnvironment('SNIPPET_PREVIEW_FONT');
    const previewMonospace =
        String.fromEnvironment('SNIPPET_PREVIEW_MONOSPACE');
    if (previewDir.isNotEmpty && previewFont.isNotEmpty) {
      // Optional local preview font, never needed by the normal test suite.
      await tester.runAsync(() async {
        final bytes = await File(previewFont).readAsBytes();
        await (FontLoader(NetcattyTheme.uiFont)
              ..addFont(Future.value(ByteData.sublistView(bytes))))
            .load();
        await (FontLoader('MaterialIcons')
              ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
            .load();
        if (previewMonospace.isNotEmpty) {
          final mono = await File(previewMonospace).readAsBytes();
          await (FontLoader('monospace')
                ..addFont(Future.value(ByteData.sublistView(mono))))
              .load();
        }
      });
    }
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_vault_v1': jsonEncode({
        'hosts': const [],
        'keys': const [],
        'customGroups': const [],
        'snippetPackages': ['Linux', 'Network', 'Empty group'],
        'snippets': [
          {
            'id': 'cpu',
            'label': 'CPU information',
            'command': 'lscpu',
            'package': 'Linux'
          },
          {
            'id': 'disk',
            'label': 'Disk usage',
            'command': 'df -h',
            'package': 'Linux'
          },
          {
            'id': 'net',
            'label': 'Network interfaces',
            'command': 'ip address',
            'package': 'Network'
          },
          {'id': 'date', 'label': 'Current date', 'command': 'date'},
        ],
      }),
    });
    final repository = await VaultRepository.open();
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
      child: RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: NetcattyTheme.build(Brightness.dark, NetcattyTheme.defaultId),
          home: const SnippetsScreen(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('CPU information'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('snippet-group-Linux')));
    await tester.pumpAndSettle();
    expect(find.text('CPU information'), findsOneWidget);
    expect(find.text('Network interfaces'), findsNothing);
    expect(tester.takeException(), isNull);

    Future<void> preview(String filename) async {
      if (previewDir.isEmpty) return;
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(previewDir).create(recursive: true);
        await File('$previewDir/$filename')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await preview('snippets-mobile-expanded.png');
    await tester.tap(find.byKey(const ValueKey('snippet-actions-cpu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester
        .showKeyboard(find.byKey(const ValueKey('snippet-edit-package')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('save-snippet')));
    await tester.pumpAndSettle();
    expect(
        tester
            .getSize(find.byKey(const ValueKey('snippet-edit-package')))
            .width,
        lessThanOrEqualTo(430));
    expect(tester.getBottomRight(find.byKey(const ValueKey('save-snippet'))).dy,
        lessThanOrEqualTo(580));
    expect(tester.takeException(), isNull);
    await preview('snippets-mobile-editor.png');
  });
}
