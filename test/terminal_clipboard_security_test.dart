import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/src/ui/custom_text_edit.dart';
import 'package:xterm2/xterm.dart';

// All clipboard contents and terminal output in this suite are inert fixtures.
// No OS clipboard or network connection is used.
class _TestClipboard {
  String text = 'TEST-ONLY clipboard content';
  int reads = 0;
  int writes = 0;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'Clipboard.getData':
        reads++;
        return {'text': text};
      case 'Clipboard.setData':
        writes++;
        text = (call.arguments as Map)['text'] as String;
        return null;
      case 'Clipboard.hasStrings':
        return {'value': text.isNotEmpty};
      default:
        return null;
    }
  }
}

Widget _view(
  Terminal terminal,
  FocusNode focus, {
  TerminalController? controller,
}) =>
    MaterialApp(
      home: Scaffold(
        body: TerminalView(
          terminal,
          key: const ValueKey('clipboard-terminal'),
          focusNode: focus,
          controller: controller,
          autofocus: true,
          // Exercise the app's existing IME customization in the same view.
          keepImeContext: true,
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _TestClipboard clipboard;

  setUp(() {
    clipboard = _TestClipboard();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, clipboard.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'focused remote OSC 52 queries never read or return the clipboard',
    (tester) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_view(terminal, focus));
      await tester.pump();
      expect(
        focus.hasFocus,
        isTrue,
        reason: 'The vulnerable implementation only read when focused',
      );
      clipboard.reads = 0;
      output.clear();

      // Both OSC terminators and a query split between SSH-like packets.
      terminal.write('\x1b]52;c;?\x07');
      terminal.write('\x1b]52;p;?\x1b\\');
      terminal.write('\x1b]5');
      terminal.write('2;c;');
      terminal.write('?\x1b');
      terminal.write('\\');
      await tester.pump(const Duration(milliseconds: 100));

      expect(clipboard.reads, 0);
      expect(output, isEmpty);
      expect(terminal.onClipboardQuery, isNull);
    },
  );

  testWidgets(
    'terminal replacement and view remount do not reinstall query access',
    (tester) async {
      final output = <String>[];
      final first = Terminal(onOutput: output.add);
      final second = Terminal(onOutput: output.add);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(_view(first, focus));
      await tester.pump();
      await tester.pumpWidget(_view(second, focus));
      await tester.pump();

      first.write('\x1b]52;c;?\x07');
      second.write('\x1b]52;c;?\x07');
      await tester.pump(const Duration(milliseconds: 100));
      expect(first.onClipboardQuery, isNull);
      expect(second.onClipboardQuery, isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_view(second, focus));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      second.write('\x1b]52;c;?\x07');
      await tester.pump(const Duration(milliseconds: 100));
      expect(clipboard.reads, 0);
      expect(output, isEmpty);
    },
  );

  testWidgets('explicit host clipboard-query callbacks remain opt in and owned',
      (
    tester,
  ) async {
    final output = <String>[];
    final requested = <String>[];
    Future<String?> allowedQuery(String selector) async {
      requested.add(selector);
      return 'explicit-public-response';
    }

    final terminal = Terminal(onOutput: output.add)
      ..onClipboardQuery = allowedQuery;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_view(terminal, focus));
    await tester.pump();
    terminal.write('\x1b]52;c;?\x07');
    await tester.pump(const Duration(milliseconds: 100));

    expect(requested, ['c']);
    expect(output, [
      '\x1b]52;c;${base64Encode(utf8.encode('explicit-public-response'))}\x1b\\',
    ]);
    expect(clipboard.reads, 0);
    await tester.pumpWidget(_view(Terminal(), focus));
    expect(terminal.onClipboardQuery, same(allowedQuery));
    await tester.pumpWidget(const SizedBox());
    expect(terminal.onClipboardQuery, same(allowedQuery));
  });

  testWidgets('focused remote clipboard writes still work', (tester) async {
    final terminal = Terminal();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_view(terminal, focus));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    terminal.write(
      '\x1b]52;c;${base64Encode(utf8.encode('TEST-ONLY remote copy'))}\x07',
    );
    await tester.pump();
    expect(clipboard.text, 'TEST-ONLY remote copy');
    expect(clipboard.writes, 1);
    expect(clipboard.reads, 0);
  });

  testWidgets('unfocused remote clipboard writes remain blocked', (
    tester,
  ) async {
    final terminal = Terminal();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_view(terminal, focus));
    await tester.pump();
    focus.unfocus();
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    terminal.write(
      '\x1b]52;c;${base64Encode(utf8.encode('TEST-ONLY not copied'))}\x07',
    );
    await tester.pump();
    expect(clipboard.writes, 0);
  });

  testWidgets('user copy selection still writes to the clipboard', (
    tester,
  ) async {
    final terminal = Terminal()..write('hello world');
    final controller = TerminalController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(_view(terminal, focus, controller: controller));
    await tester.pump();
    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(5, 0),
    );
    await tester.pump();

    final result = Actions.invoke(
      tester.element(find.byType(CustomTextEdit)),
      CopySelectionTextIntent.copy,
    );
    if (result is Future) await result;
    await tester.pump();
    expect(clipboard.text, 'hello');
    expect(clipboard.writes, 1);
    expect(clipboard.reads, 0);
  });

  testWidgets('user paste still reads and sends clipboard text once', (
    tester,
  ) async {
    clipboard.text = 'TEST-ONLY manual paste';
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_view(terminal, focus));
    await tester.pump();
    output.clear();
    clipboard.reads = 0;

    final result = Actions.invoke(
      tester.element(find.byType(CustomTextEdit)),
      const PasteTextIntent(SelectionChangedCause.keyboard),
    );
    if (result is Future) await result;
    await tester.pump();
    expect(clipboard.reads, 1);
    expect(output, ['TEST-ONLY manual paste']);
  });
}
