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
  List<String> order = defaultTerminalQuickKeys,
  void Function(String value)? onSend,
}) =>
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: TerminalSpecialKeys(
            order: order,
            customKeys: const [],
            inputController: TerminalInputController(),
            onSend: (value, {bool enter = false}) => onSend?.call(value),
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

  testWidgets('a 13th key keeps two rows; Ctrl+C sends ^C', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      _toolbar(
        keyboardOpen: ValueNotifier(true),
        onShowKeyboard: _ignore,
        order: const [...defaultTerminalQuickKeys, 'ctrlD'],
        onSend: sent.add,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.text('Ctrl+D')).dy,
      closeTo(tester.getCenter(find.text('Shift')).dy, 1),
    );
    final ctrlC = find.text('Ctrl+C');
    expect(ctrlC, findsOneWidget);
    await tester.tap(ctrlC);
    await tester.pump();
    expect(sent, ['\x03']);
  });

  testWidgets('removed default keys stay removed', (tester) async {
    await tester.pumpWidget(
      _toolbar(
        keyboardOpen: ValueNotifier(true),
        onShowKeyboard: _ignore,
        order: const ['escape', 'tab', 'ctrlC'],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ctrl+C'), findsOneWidget);
    expect(find.text('Alt'), findsNothing);
  });
}
