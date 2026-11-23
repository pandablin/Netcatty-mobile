import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/ssh/sftp_service.dart';

// Deliberately simple concatenation, like local and SAF target path builders.
// These services never access a real filesystem, device, account or network.
class _MemoryService extends FileTransferService {
  _MemoryService(this.id, {this.isLocal = false});

  @override
  final String id;
  @override
  final bool isLocal;
  final listings = <String, List<RemoteEntry>>{};
  final files = <String, Uint8List>{};
  final mutations = <String>[];
  int reads = 0;

  @override
  String get displayName => id;
  @override
  String get rootPath => '/';
  @override
  String displayPath(String path) => path;
  @override
  String joinPath(String path, String name) => '$path/$name';
  @override
  String parentPath(String path) => path.substring(0, path.lastIndexOf('/'));
  @override
  Future<List<RemoteEntry>> list(String path) async => listings[path] ?? [];
  @override
  Stream<Uint8List> readStream(String path,
      {int startOffset = 0, TransferProgressCallback? onProgress}) async* {
    reads++;
    yield Uint8List.fromList(
        (files[path] ?? Uint8List(0)).sublist(startOffset));
  }

  @override
  Future<void> writeStream(String path, Stream<Uint8List> stream,
      {int startOffset = 0,
      bool truncate = true,
      TransferProgressCallback? onProgress}) async {
    mutations.add('write:$path');
    final bytes = BytesBuilder();
    if (!truncate) bytes.add(files[path]!.sublist(0, startOffset));
    await for (final chunk in stream) {
      bytes.add(chunk);
      onProgress?.call(bytes.length - startOffset);
    }
    files[path] = bytes.takeBytes();
  }

  @override
  Future<int?> fileSize(String path) async => files[path]?.length;
  @override
  Future<void> mkdir(String path) async => mutations.add('mkdir:$path');
  @override
  Future<void> ensureDirectory(String path) async => mkdir(path);
  @override
  Future<void> rename(String from, String to) async {
    mutations.add('rename:$from->$to');
    files[to] = files.remove(from)!;
  }

  @override
  Future<void> delete(RemoteEntry entry) async {
    mutations.add('delete:${entry.path}');
    files.remove(entry.path);
  }
}

RemoteEntry _entry(String name, {bool directory = false}) => RemoteEntry(
    name: name, path: '/remote/entry', isDirectory: directory, size: 3);

void main() {
  const invalid = [
    '',
    '.',
    '..',
    '../outside',
    '/absolute',
    'a/b',
    r'a\b',
    'a\u0000b'
  ];
  for (final name in invalid) {
    for (final directory in [false, true]) {
      test(
          'rejects unsafe top-level name ${jsonEncode(name)} directory=$directory',
          () async {
        final source = _MemoryService('source');
        final target = _MemoryService('target', isLocal: true);
        await expectLater(
          transferEntry(
              source, _entry(name, directory: directory), target, '/chosen'),
          throwsFormatException,
        );
        expect(source.reads, 0);
        expect(target.mutations, isEmpty,
            reason: 'Reject before any temporary file, directory or rename');
      });
    }
  }

  test('recursive listing cannot inject a traversing child path', () async {
    final source = _MemoryService('source');
    final target = _MemoryService('target', isLocal: true);
    final folder = _entry('folder', directory: true);
    source.listings[folder.path] = [_entry('../../outside')];
    await expectLater(transferEntry(source, folder, target, '/chosen'),
        throwsFormatException);
    expect(source.reads, 0);
    expect(target.files, isEmpty);
    expect(target.mutations, ['mkdir:/chosen/folder']);
  });

  test('size scanning rejects malformed child names before transfer', () async {
    final source = _MemoryService('source');
    final folder = _entry('folder', directory: true);
    source.listings[folder.path] = [_entry('../outside')];
    await expectLater(
        calculateTransferSize(source, folder), throwsFormatException);
    expect(source.reads, 0);
  });

  test('normal Unicode and shell-special filenames remain data and transfer',
      () async {
    final source = _MemoryService('source');
    final target = _MemoryService('target', isLocal: true);
    final folder = _entry('目录', directory: true);
    final child = RemoteEntry(
        name: "a 'quoted' \$name.txt",
        path: '/remote/file',
        isDirectory: false,
        size: 3);
    source.listings[folder.path] = [child];
    source.files[child.path] = Uint8List.fromList([1, 2, 3]);
    expect(await transferEntry(source, folder, target, '/chosen'), 3);
    expect(target.files['/chosen/目录/${child.name}'], [1, 2, 3]);
    expect(source.reads, 1);
    expect(target.files.keys.any((path) => path.endsWith('.netcatty-part')),
        isFalse);
  });
}
