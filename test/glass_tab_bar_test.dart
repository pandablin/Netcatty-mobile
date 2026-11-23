import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/presentation/widgets/glass.dart';

void main() {
  testWidgets('glass tab bar selects tabs and slides its indicator',
      (tester) async {
    var selected = 0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          home: Scaffold(
            extendBody: true,
            body: const SizedBox.expand(),
            bottomNavigationBar: GlassTabBar(
              selectedIndex: selected,
              onSelected: (value) => setState(() => selected = value),
              items: const [
                GlassTabItem(
                  icon: Icons.dns_outlined,
                  selectedIcon: Icons.dns,
                  label: '保险库',
                ),
                GlassTabItem(
                  icon: Icons.terminal_outlined,
                  selectedIcon: Icons.terminal,
                  label: '终端',
                ),
                GlassTabItem(
                  icon: Icons.settings_outlined,
                  selectedIcon: Icons.settings,
                  label: '设置',
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final indicator = find.byKey(const ValueKey('glass-tab-indicator'));
    final before = tester.getCenter(indicator).dx;
    expect(find.byIcon(Icons.dns), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
    final after = tester.getCenter(indicator).dx;
    expect(after, greaterThan(before));
    expect(
      (after - tester.getCenter(find.text('设置')).dx).abs(),
      lessThan(1),
    );
    expect(tester.takeException(), isNull);
  });
}
