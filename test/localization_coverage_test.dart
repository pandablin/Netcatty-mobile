import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

// Consume each whole quoted literal, including empty/English ones, before
// looking for Chinese. Searching for Han inside the regex can incorrectly
// start at the closing quote of an earlier empty string on the same line.
final _quotedLiteral = RegExp(
  r'''r'([^']*)'|r"([^"]*)"|'((?:\\.|[^'\\])*)'|"((?:\\.|[^"\\])*)"''',
);

Iterable<String> _sourceStringLiterals(String line) sync* {
  for (final match in _quotedLiteral.allMatches(line)) {
    yield match.group(1) ?? match.group(2) ?? match.group(3) ?? match.group(4)!;
  }
}

void main() {
  test('source literals consume empty strings before later Chinese strings',
      () {
    expect(
      _sourceStringLiterals(
        "const PopupMenuItem(value: '', child: LText('未分组')),",
      ),
      ['', '未分组'],
    );
  });

  test('source literals keep multiple single and double quoted values separate',
      () {
    expect(
      _sourceStringLiterals(r'''row('English', '中文', "", "选择分组");'''),
      ['English', '中文', '', '选择分组'],
    );
    expect(
      _sourceStringLiterals("'topLeft' => '左上',"),
      ['topLeft', '左上'],
    );
  });

  test(
      'escaped quotes stay inside their literal instead of becoming delimiters',
      () {
    expect(
      _sourceStringLiterals(
        r'''row('it\'s 中文', "say \"你好\"", '分组');''',
      ),
      [r"it\'s 中文", r'say \"你好\"', '分组'],
    );
  });

  test('raw literals do not treat backslashes as quote escapes', () {
    expect(
      _sourceStringLiterals(r'''row(r'路径\中文', r"字\", '分组');'''),
      [r'路径\中文', '字\\', '分组'],
    );
  });

  test('every Chinese source message has an English rendering', () {
    NetcattyLocalizations.use('en');
    final missing = <String>{};
    final han = RegExp(r'[\u4e00-\u9fff]');
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains(
          '${Platform.pathSeparator}localization${Platform.pathSeparator}')) {
        continue;
      }
      for (final line in entity.readAsLinesSync()) {
        for (final source in _sourceStringLiterals(line)) {
          if (!han.hasMatch(source)) continue;
          final translated = NetcattyLocalizations.text(source);
          if (han.hasMatch(translated)) missing.add('$source -> $translated');
        }
      }
    }
    final details = missing.toList()..sort();
    expect(missing, isEmpty, reason: details.join('\n'));
  });

  test('security errors render in English with runtime values and wrappers',
      () {
    NetcattyLocalizations.use('en');
    addTearDown(() => NetcattyLocalizations.use('zh-CN'));
    expect(
      localized('Bad state: 云端响应超过安全大小限制（33554432 字节），已停止读取'),
      'Bad state: The cloud response exceeds the safety limit (33554432 bytes); reading stopped',
    );
    expect(
      localized('FormatException: 文件名包含不安全的路径，已停止传输'),
      'FormatException: The filename contains an unsafe path. Transfer stopped',
    );
    expect(
      localized('云端未找到 netcatty-vault.json，且本机没有可同步数据。'
          '未上传空保险库，请检查云同步目录或地址，并先在桌面端上传数据'),
      'No netcatty-vault.json was found in the cloud, and this device has no data to sync. '
      'No empty vault was uploaded. Check the sync folder or address, and upload your data from desktop first',
    );
  });

  test('sync status renders materialized entity counts without losing values',
      () {
    NetcattyLocalizations.use('en');
    addTearDown(() => NetcattyLocalizations.use('zh-CN'));
    expect(
      localized('首次上传完成；本机现有：12 台主机、53 条脚本、4 个密钥'),
      'Initial upload complete; on this device: 12 hosts, 53 scripts, 4 keys',
    );
    expect(
      localized('同步完成；云端读取：12 台主机、53 条脚本、4 个密钥；'
          '本机现有：12 台主机、53 条脚本、4 个密钥'),
      'Sync complete; Read from cloud: 12 hosts, 53 scripts, 4 keys; '
      'on this device: 12 hosts, 53 scripts, 4 keys',
    );
    expect(
      localized('云端保险库为空；云端读取：0 台主机、0 条脚本、0 个密钥；'
          '本机现有：12 台主机、53 条脚本、4 个密钥'),
      'The cloud vault is empty; Read from cloud: 0 hosts, 0 scripts, 0 keys; '
      'on this device: 12 hosts, 53 scripts, 4 keys',
    );
  });
}
