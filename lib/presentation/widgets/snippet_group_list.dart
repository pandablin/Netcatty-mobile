import 'package:flutter/material.dart';

import '../../domain/models/host.dart';
import '../../domain/models/snippet_group.dart';
import '../localization/localized_widgets.dart';

class SnippetGroupList extends StatefulWidget {
  const SnippetGroupList({
    super.key,
    required this.snippets,
    required this.itemBuilder,
    this.packages = const [],
    this.padding = const EdgeInsets.all(12),
  });

  final List<CommandSnippet> snippets;
  final List<String> packages;
  final Widget Function(BuildContext, CommandSnippet) itemBuilder;
  final EdgeInsetsGeometry padding;

  @override
  State<SnippetGroupList> createState() => _SnippetGroupListState();
}

class _SnippetGroupListState extends State<SnippetGroupList> {
  String? _expanded;

  @override
  Widget build(BuildContext context) {
    final groups =
        groupCommandSnippets(widget.snippets, packages: widget.packages);
    return ListView.separated(
      padding: widget.padding,
      itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final group = groups[index];
        final expanded = _expanded == group.key;
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Semantics(
                button: true,
                expanded: expanded,
                child: ListTile(
                  key: ValueKey('snippet-group-${group.key}'),
                  leading: Icon(expanded
                      ? Icons.folder_open_outlined
                      : Icons.folder_outlined),
                  title: group.packageName == null
                      ? const LText('未分组')
                      : Text(group.packageName!),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${group.snippets.length}',
                          style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(width: 10),
                      Icon(expanded ? Icons.expand_less : Icons.expand_more),
                    ],
                  ),
                  onTap: () =>
                      setState(() => _expanded = expanded ? null : group.key),
                ),
              ),
              if (expanded) ...[
                const Divider(height: 1),
                if (group.snippets.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: LText('该分组暂无片段'),
                  ),
                for (final snippet in group.snippets)
                  widget.itemBuilder(context, snippet),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Selecting a row only returns the snippet; execution remains with the caller.
Future<CommandSnippet?> showGroupedSnippetPicker(
  BuildContext context, {
  required List<CommandSnippet> snippets,
  List<String> packages = const [],
}) =>
    showModalBottomSheet<CommandSnippet>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: Column(
          children: [
            ListTile(
              title: const LText('选择命令片段'),
              trailing: IconButton(
                tooltip: localized('取消'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            Expanded(
              child: SnippetGroupList(
                snippets: snippets,
                packages: packages,
                itemBuilder: (context, snippet) => ListTile(
                  key: ValueKey('pick-snippet-${snippet.id}'),
                  leading: const Icon(Icons.code),
                  title: Text(snippet.label),
                  subtitle: Text(snippet.command,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(context, snippet),
                ),
              ),
            ),
          ],
        ),
      ),
    );
