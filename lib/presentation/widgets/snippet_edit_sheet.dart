import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models/host.dart';
import '../../domain/models/snippet_group.dart';
import '../localization/localized_widgets.dart';

class SnippetEditSheet extends StatefulWidget {
  const SnippetEditSheet({super.key, this.snippet, this.packages = const []});
  final CommandSnippet? snippet;
  final List<String> packages;

  @override
  State<SnippetEditSheet> createState() => _SnippetEditSheetState();
}

class _SnippetEditSheetState extends State<SnippetEditSheet> {
  late final _label = TextEditingController(text: widget.snippet?.label);
  late final _command = TextEditingController(text: widget.snippet?.command);
  late final _package =
      TextEditingController(text: widget.snippet?.packageName);
  late bool _autoRun = widget.snippet?.autoRun ?? true;

  @override
  void dispose() {
    _label.dispose();
    _command.dispose();
    _package.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            16, 20, 16, MediaQuery.viewInsetsOf(context).bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LText(widget.snippet == null ? '新建命令片段' : '编辑命令片段',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('snippet-edit-label'),
              controller: _label,
              decoration: LInputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('snippet-edit-package'),
              controller: _package,
              decoration: LInputDecoration(
                labelText: '分组',
                hintText: '输入新分组或选择已有分组',
                suffixIcon: PopupMenuButton<String>(
                  key: const ValueKey('snippet-choose-package'),
                  tooltip: localized('选择分组'),
                  icon: const Icon(Icons.arrow_drop_down),
                  onSelected: (value) => _package.text = value,
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: '', child: LText('未分组')),
                    for (final package in widget.packages)
                      PopupMenuItem(value: package, child: Text(package)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('snippet-edit-command'),
              controller: _command,
              minLines: 4,
              maxLines: 10,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: LInputDecoration(labelText: '命令'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const LText('发送后立即执行'),
              value: _autoRun,
              onChanged: (value) => setState(() => _autoRun = value),
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('save-snippet'),
                onPressed: () {
                  if (_label.text.trim().isEmpty ||
                      _command.text.trim().isEmpty) {
                    return;
                  }
                  Navigator.pop(
                    context,
                    CommandSnippet({
                      ...?widget.snippet?.data,
                      'id': widget.snippet?.id ?? const Uuid().v4(),
                      'label': _label.text.trim(),
                      'package': _package.text.trim(),
                      'command': _command.text,
                      'noAutoRun': !_autoRun,
                      'kind': widget.snippet?.data['kind'] ?? 'snippet',
                    }),
                  );
                },
                child: const LText('保存'),
              ),
            ),
          ],
        ),
      );
}
