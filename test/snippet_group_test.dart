import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/snippet_group.dart';
import 'package:netcatty_mobile/presentation/widgets/snippet_group_list.dart';

void main() {
  test(
      'desktop package order, inferred packages, empty groups and ungrouped are distinct',
      () {
    final snippets = [
      CommandSnippet({'id': 'b', 'package': 'Inferred'}),
      CommandSnippet({'id': 'a', 'package': 'Known'}),
      CommandSnippet({'id': 'c', 'package': ''}),
      CommandSnippet({'id': 'd', 'package': '未分组'}),
      CommandSnippet({'id': 'e'}),
    ];
    final groups = groupCommandSnippets(snippets,
        packages: ['Known', 'Empty', 'Known', ' ']);
    expect(groups.map((group) => group.packageName),
        ['Known', 'Empty', 'Inferred', '未分组', null]);
    expect(groups[1].snippets, isEmpty);
    expect(groups.last.snippets.map((snippet) => snippet.id), ['c', 'e']);
    expect(groups[3].key, isNot(groups.last.key));
  });

  testWidgets(
      'grouped terminal picker returns exactly the selected snippet without execution',
      (tester) async {
    final a = CommandSnippet({
      'id': 'a',
      'label': 'Command A',
      'command': 'printf A',
      'package': 'Tools'
    });
    final b = CommandSnippet({
      'id': 'b',
      'label': 'Command B',
      'command': 'printf B',
      'package': 'Ops'
    });
    CommandSnippet? selected;
    var returned = 0;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      selected = await showGroupedSnippetPicker(context,
                          snippets: [a, b]);
                      returned++;
                    },
                    child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(returned, 0);
    expect(find.text('Command A'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('snippet-group-Ops')));
    await tester.pumpAndSettle();
    expect(find.text('Command A'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pick-snippet-b')));
    await tester.pumpAndSettle();
    expect(identical(selected, b), isTrue);
    expect(returned, 1);
    expect(find.text('选择命令片段'), findsNothing);
  });
}
