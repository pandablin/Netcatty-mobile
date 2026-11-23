import 'host.dart';
import 'vault.dart';

/// Desktop stores the selected group in `snippet.package`, and keeps explicitly
/// created (including empty) groups in the vault's `snippetPackages` array.
extension CommandSnippetGrouping on CommandSnippet {
  String? get packageName {
    final value = data['package'];
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }
}

extension VaultSnippetGroups on VaultData {
  List<String> get snippetPackages {
    final value = extras['snippetPackages'];
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }
}

class SnippetGroup {
  const SnippetGroup({required this.packageName, required this.snippets});
  final String? packageName;
  final List<CommandSnippet> snippets;
  String get key => packageName ?? '';
}

/// Preserve desktop group order, then infer groups from individual snippets.
/// Ungrouped snippets stay in a distinct final section, never in a named group
/// that merely happens to be called "未分组".
List<SnippetGroup> groupCommandSnippets(
  Iterable<CommandSnippet> snippets, {
  Iterable<String> packages = const [],
}) {
  final groups = <String, List<CommandSnippet>>{};
  for (final package in packages) {
    final name = package.trim();
    if (name.isNotEmpty) groups.putIfAbsent(name, () => []);
  }
  final ungrouped = <CommandSnippet>[];
  for (final snippet in snippets) {
    final name = snippet.packageName;
    if (name == null) {
      ungrouped.add(snippet);
    } else {
      groups.putIfAbsent(name, () => []).add(snippet);
    }
  }
  return [
    for (final entry in groups.entries)
      SnippetGroup(packageName: entry.key, snippets: entry.value),
    if (ungrouped.isNotEmpty)
      SnippetGroup(packageName: null, snippets: ungrouped),
  ];
}
