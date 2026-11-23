import '../domain/models/host.dart';

int _byName(HostProfile a, HostProfile b) =>
    a.label.toLowerCase().compareTo(b.label.toLowerCase());

/// Orders hosts for the vault list.
///
/// * `name`: pinned first, then by name.
/// * `recent`: pinned first, then most recently connected, then by name.
/// * `manual`: the order in [manualOrder]; hosts not in it (e.g. added
///   later or synced from another device) follow, sorted by name.
List<HostProfile> sortHosts(
  Iterable<HostProfile> hosts, {
  required String mode,
  List<String> manualOrder = const [],
}) {
  final sorted = hosts.toList();
  switch (mode) {
    case 'manual':
      final position = <String, int>{
        for (var index = 0; index < manualOrder.length; index++)
          manualOrder[index]: index,
      };
      sorted.sort((a, b) {
        final left = position[a.id];
        final right = position[b.id];
        if (left != null && right != null) return left.compareTo(right);
        if (left != null) return -1;
        if (right != null) return 1;
        return _byName(a, b);
      });
    case 'recent':
      sorted.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        final recent = b.lastConnectedAt.compareTo(a.lastConnectedAt);
        return recent != 0 ? recent : _byName(a, b);
      });
    default:
      sorted.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return _byName(a, b);
      });
  }
  return sorted;
}
