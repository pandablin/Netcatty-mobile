import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';

void main() {
  test('stream decoding keeps a CJK character split across packets', () async {
    final bytes = utf8.encode('中文');
    final packets = StreamController<Uint8List>();
    final text =
        const Utf8Decoder(allowMalformed: true).bind(packets.stream).join();
    // Split inside the first character's three bytes.
    packets
      ..add(Uint8List.fromList(bytes.sublist(0, 2)))
      ..add(Uint8List.fromList(bytes.sublist(2)));
    await packets.close();
    expect(await text, '中文');
  });

  group('TelnetStreamFilter', () {
    test('refuses DO/WILL and never answers DONT/WONT', () {
      final replies = <List<int>>[];
      final visible = TelnetStreamFilter().process(
        [255, 253, 24, 255, 251, 1, 255, 254, 3, 255, 252, 5, 104, 105],
        replies.add,
      );
      expect(visible, [104, 105]);
      expect(replies, [
        [255, 252, 24],
        [255, 254, 1],
      ]);
    });

    test('keeps command state across chunk boundaries', () {
      final filter = TelnetStreamFilter();
      final replies = <List<int>>[];
      expect(filter.process([65, 255], replies.add), [65]);
      expect(filter.process([253], replies.add), isEmpty);
      expect(filter.process([31, 66], replies.add), [66]);
      expect(replies, [
        [255, 252, 31],
      ]);
    });

    test('unescapes 0xFF data and skips subnegotiation', () {
      final visible = TelnetStreamFilter().process(
        [255, 255, 255, 250, 24, 1, 255, 240, 67],
        (_) => fail('no reply expected'),
      );
      expect(visible, [255, 67]);
    });
  });
}
