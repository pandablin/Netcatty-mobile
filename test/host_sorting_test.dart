import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/host_sorting.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';

HostProfile _host(String id, String label,
        {int last = 0, bool pinned = false}) =>
    HostProfile({
      'id': id,
      'label': label,
      'hostname': '$id.example.invalid',
      'lastConnectedAt': last,
      'pinned': pinned,
    });

List<String> _labels(List<HostProfile> hosts) =>
    hosts.map((host) => host.label).toList();

void main() {
  final hosts = [
    _host('c', 'Charlie', last: 30),
    _host('a', 'alpha', last: 10),
    _host('b', 'Bravo', last: 20, pinned: true),
  ];

  test('name order keeps pinned hosts first', () {
    expect(
        _labels(sortHosts(hosts, mode: 'name')), ['Bravo', 'alpha', 'Charlie']);
  });

  test('recent order puts the last connected first', () {
    final unpinned = [for (final host in hosts) host.copyWith(pinned: false)];
    expect(_labels(sortHosts(unpinned, mode: 'recent')),
        ['Charlie', 'Bravo', 'alpha']);
  });

  test('manual order follows the saved ids; new hosts go last by name', () {
    final withNew = [...hosts, _host('d', 'Delta'), _host('e', 'Echo')];
    expect(
      _labels(sortHosts(withNew, mode: 'manual', manualOrder: ['c', 'a', 'b'])),
      ['Charlie', 'alpha', 'Bravo', 'Delta', 'Echo'],
    );
  });

  test('sort settings round-trip and fall back safely', () {
    final settings = AppSettings.fromJson(const {
      'hostSortMode': 'manual',
      'hostOrder': ['b', 'a'],
    });
    expect(settings.hostSortMode, 'manual');
    expect(settings.hostOrder, ['b', 'a']);
    expect(settings.toJson()['hostOrder'], ['b', 'a']);
    expect(
        AppSettings.fromJson(const {'hostSortMode': 'x'}).hostSortMode, 'name');
    expect(const AppSettings().hostOrder, isEmpty);
  });
}
