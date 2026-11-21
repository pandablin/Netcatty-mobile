import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/presentation/widgets/terminal_special_keys.dart';

void _ignore() {}

Widget _toolbar({
  required ValueNotifier<bool> keyboardOpen,
  required VoidCallback onShowKeyboard,
}) =>
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: TerminalSpecialKeys(
            order: defaultTerminalQuickKeys,
            customKeys: const [],
            inputController: TerminalInputController(),
            onSend: (value, {bool enter = false}) {},
            onAi: _ignore,
            onPortForward: null,
            onSystemManagement: null,
            pictureInPicture: false,
            onPictureInPicture: _ignore,
            fullscreen: false,
            onFullscreen: _ignore,
            split: false,
            onSplit: null,
            keyboardOpen: keyboardOpen,
            onShowKeyboard: onShowKeyboard,
          ),
        ),
      ),
    );

void main() {
  test('keyboard suggestion mode defaults on and round-trips', () {
    expect(const AppSettings().terminalImeSuggestions, isTrue);
    expect(AppSettings.fromJson(const {}).terminalImeSuggestions, isTrue);
    final off = AppSettings.fromJson(const {'terminalImeSuggestions': false});
    expect(off.terminalImeSuggestions, isFalse);
    expect(off.toJson()['terminalImeSuggestions'], isFalse);
  });

  test('tap-to-keyboard defaults on and round-trips through JSON', () {
    expect(const AppSettings().terminalTapToKeyboard, isTrue);
    expect(AppSettings.fromJson(const {}).terminalTapToKeyboard, isTrue);
    final off = AppSettings.fromJson(const {'terminalTapToKeyboard': false});
    expect(off.terminalTapToKeyboard, isFalse);
    expect(off.toJson()['terminalTapToKeyboard'], isFalse);
    expect(
      off.copyWith(terminalTapToKeyboard: true).terminalTapToKeyboard,
      isTrue,
    );
  });

  testWidgets('keyboard button shows the keyboard when it is closed',
      (tester) async {
    final open = ValueNotifier<bool>(false);
    addTearDown(open.dispose);
    var shows = 0;
    await tester.pumpWidget(
      _toolbar(keyboardOpen: open, onShowKeyboard: () => shows++),
    );

    expect(find.byTooltip('弹出键盘'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('terminal-action-hide-keyboard')));
    await tester.pump();
    expect(shows, 1);

    open.value = true;
    await tester.pump();
    expect(find.byTooltip('收起键盘'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('terminal-action-hide-keyboard')));
    await tester.pump();
    expect(shows, 1, reason: 'an open keyboard is hidden, not shown again');
  });
}
