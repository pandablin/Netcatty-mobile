import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/presentation/widgets/context_menu.dart';

const _previewKey = ValueKey('test-menu-preview');
const _anchor = Rect.fromLTWH(32, 120, 320, 90);

class _MenuProbe {
  final results = <String?>[];
  int actions = 0;

  Future<void> open(BuildContext context, double previewHeight) async {
    final result = await showContextMenu<String>(
      context: context,
      anchor: _anchor,
      preview: SizedBox(
        key: _previewKey,
        height: previewHeight,
        child: const ColoredBox(
          color: Colors.blueGrey,
          child: Center(child: Text('Host preview')),
        ),
      ),
      actions: [
        for (var index = 0; index < 5; index++)
          ContextMenuAction(
            value: 'action-$index',
            label: 'Action ${index + 1}',
            icon: Icons.terminal,
            destructive: index == 4,
          ),
      ],
    );
    results.add(result);
    if (result != null) actions++;
  }
}

Finder get _panel => find.byWidgetPredicate(
    (widget) => widget is Material && widget.elevation == 10);
Finder _action(int index) => find.byKey(ValueKey('context-menu-action-$index'));

Future<void> _openMenu(WidgetTester tester, _MenuProbe probe,
    {required Size size,
    double previewHeight = 100,
    EdgeInsets safePadding = EdgeInsets.zero}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(padding: safePadding),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => probe.open(context, previewHeight),
            child: const Text('Open menu'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open menu'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('landscape menu is bounded and every action is scroll reachable',
      (tester) async {
    final probe = _MenuProbe();
    await _openMenu(tester, probe,
        size: const Size(740, 320), previewHeight: 180);

    expect(tester.getRect(_panel).bottom, lessThanOrEqualTo(312));
    expect(_action(4).hitTestable(), findsNothing,
        reason: 'The last row starts outside the bounded scroll viewport');
    await tester.drag(_panel, const Offset(0, -70));
    await tester.pumpAndSettle();
    expect(probe.actions, 0,
        reason: 'A scroll gesture must not select an action');
    for (var index = 0; index < 5; index++) {
      await tester.ensureVisible(_action(index));
      await tester.pumpAndSettle();
      expect(_action(index).hitTestable(), findsOneWidget);
      expect(probe.actions, 0,
          reason: 'Showing and scrolling the menu must not run an action');
    }
    await tester.tap(_action(4));
    await tester.pumpAndSettle();
    expect(probe.results, ['action-4']);
    expect(probe.actions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait keeps the original anchor and natural menu height',
      (tester) async {
    final probe = _MenuProbe();
    await _openMenu(tester, probe, size: const Size(390, 844));
    final preview = tester.getRect(find.byKey(_previewKey));
    final panel = tester.getRect(_panel);
    expect(preview.top, _anchor.top);
    expect(preview.left, _anchor.left);
    expect(preview.height, 100);
    expect(panel.top, preview.bottom + 10);
    expect(panel.height, 250); // Five 48px rows, three 1px and one 7px divider.
    for (var index = 0; index < 5; index++) {
      expect(_action(index).hitTestable(), findsOneWidget);
    }
    expect(probe.actions, 0);
    await tester.tap(_action(0));
    await tester.pumpAndSettle();
    expect(probe.results, ['action-0']);
    expect(probe.actions, 1);
  });

  testWidgets('oversized preview still leaves a usable scrolling action area',
      (tester) async {
    final probe = _MenuProbe();
    await _openMenu(tester, probe,
        size: const Size(740, 320),
        previewHeight: 500,
        safePadding: const EdgeInsets.only(top: 24, bottom: 16));
    final panel = tester.getRect(_panel);
    expect(panel.top, greaterThanOrEqualTo(32));
    expect(panel.bottom, lessThanOrEqualTo(296));
    expect(panel.height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(_action(4));
    await tester.pumpAndSettle();
    expect(_action(4).hitTestable(), findsOneWidget);
    await tester.tap(_action(4));
    await tester.pumpAndSettle();
    expect(probe.results, ['action-4']);
    expect(probe.actions, 1);
  });

  testWidgets('outside tap and system back cancel without invoking an action',
      (tester) async {
    final probe = _MenuProbe();
    await _openMenu(tester, probe, size: const Size(390, 844));
    await tester.tapAt(const Offset(380, 40));
    await tester.pumpAndSettle();
    expect(probe.results, [null]);
    expect(probe.actions, 0);

    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(probe.results, [null, null]);
    expect(probe.actions, 0);
  });
}
