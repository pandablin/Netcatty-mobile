import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../domain/models/snippet_group.dart';
import '../widgets/empty_state.dart';
import '../widgets/glass.dart';
import '../widgets/snippet_edit_sheet.dart';
import '../widgets/snippet_group_list.dart';

class SnippetsScreen extends ConsumerWidget {
  const SnippetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultControllerProvider).data;
    final snippets = vault?.snippets ?? const <CommandSnippet>[];
    final packages = groupCommandSnippets(snippets,
            packages: vault?.snippetPackages ?? const [])
        .map((group) => group.packageName)
        .whereType<String>()
        .toList(growable: false);
    return SafeArea(
      // The list scrolls under the floating glass tab bar.
      bottom: false,
      child: Scaffold(
        appBar: AppBar(
          title: const LText('命令片段'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: GlassIconButton(
                onPressed: () => _edit(context, ref),
                icon: const Icon(Icons.add),
              ),
            ),
          ],
        ),
        body: snippets.isEmpty && packages.isEmpty
            ? EmptyState(
                icon: Icons.code,
                title: '还没有命令片段',
                subtitle: '保存常用命令，一次点击即可发送到当前终端。',
                action: FilledButton.icon(
                  onPressed: () => _edit(context, ref),
                  icon: const Icon(Icons.add),
                  label: const LText('新建片段'),
                ),
              )
            : SnippetGroupList(
                snippets: snippets,
                packages: packages,
                padding: EdgeInsets.fromLTRB(
                  12,
                  12,
                  12,
                  MediaQuery.paddingOf(context).bottom + 12,
                ),
                itemBuilder: (_, snippet) {
                  return ListTile(
                    leading: const Icon(Icons.code),
                    title: LText(snippet.label),
                    subtitle: LText(
                      snippet.command,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    onTap: () {
                      final active = ref.read(sessionControllerProvider).active;
                      if (active == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: LText('请先建立终端会话')),
                        );
                      } else {
                        ref
                            .read(sessionControllerProvider.notifier)
                            .send(snippet.command, enter: snippet.autoRun);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: LText('已发送到 ${active.host.label}'),
                          ),
                        );
                      }
                    },
                    trailing: PopupMenuButton<_SnippetAction>(
                      key: ValueKey('snippet-actions-${snippet.id}'),
                      tooltip: localized('片段操作'),
                      onSelected: (action) async {
                        switch (action) {
                          case _SnippetAction.edit:
                            await _edit(context, ref, snippet);
                            break;
                          case _SnippetAction.delete:
                            await _delete(context, ref, snippet);
                            break;
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: _SnippetAction.edit,
                          child: Row(
                            children: [
                              Icon(Icons.edit_outlined),
                              SizedBox(width: 12),
                              LText('编辑'),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          key: ValueKey('delete-snippet-${snippet.id}'),
                          value: _SnippetAction.delete,
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_outline,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              const SizedBox(width: 12),
                              LText(
                                '删除',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    CommandSnippet? snippet,
  ]) async {
    final vault = ref.read(vaultControllerProvider).data;
    final packages = groupCommandSnippets(vault?.snippets ?? const [],
            packages: vault?.snippetPackages ?? const [])
        .map((group) => group.packageName)
        .whereType<String>()
        .toList(growable: false);
    final result = await showModalBottomSheet<CommandSnippet>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) =>
          SnippetEditSheet(snippet: snippet, packages: packages),
    );
    if (result == null) return;
    await ref.read(vaultControllerProvider.notifier).upsertSnippet(result);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    CommandSnippet snippet,
  ) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: const LText('删除命令片段？'),
            content: LText(
              '将删除“${snippet.label}”，此操作可通过云同步传播到其他设备。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                key: const ValueKey('confirm-delete-snippet'),
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: const LText('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final controller = ref.read(vaultControllerProvider.notifier);
    await controller.deleteSnippet(snippet.id);
  }
}

enum _SnippetAction { edit, delete }
