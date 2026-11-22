import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/settings.dart';
import '../infrastructure/ssh/ssh_service.dart';
import 'session_controller.dart';
import 'settings_controller.dart';

/// Max sessions listed in the expanded Dynamic Island (keeps the payload far
/// below ActivityKit's 4 KB limit).
const maxLiveActivitySessions = 6;

/// Builds the payload sent to the iOS Live Activity, or null when no activity
/// should be shown.
Map<String, Object?>? buildLiveActivityPayload({
  required SessionState sessions,
  required AppSettings settings,
  required String? Function(String sessionId) lastCommandFor,
  required bool english,
}) {
  if (!settings.liveActivityEnabled || sessions.sessions.isEmpty) return null;
  final active = sessions.active!;
  Map<String, Object?> describe(ActiveTerminalSession session) => {
        'name': _label(session),
        'distro': session.systemInfo?.distro ?? session.host.distro,
        'connected': session.connected,
      };
  final listed = <ActiveTerminalSession>[
    active,
    ...sessions.sessions.where((session) => session.id != active.id),
  ].take(maxLiveActivitySessions);
  final host = active.host;
  final user = host.username.trim();
  final address = host.hostname.trim();
  return {
    'lang': english ? 'en' : 'zh',
    'activeName': _label(active),
    'activeDistro': active.systemInfo?.distro ?? host.distro,
    'activeConnected': active.connected,
    'activeAddress': user.isEmpty ? address : '$user@$address',
    'command':
        settings.liveActivityShowCommand ? lastCommandFor(active.id) ?? '' : '',
    'connectedSince': active.connectedAt.millisecondsSinceEpoch,
    'count': sessions.sessions.length,
    'sessions': listed.map(describe).toList(growable: false),
  };
}

String _label(ActiveTerminalSession session) {
  final label = session.host.label.trim();
  return label.isEmpty ? session.host.hostname : label;
}

final liveActivityControllerProvider = Provider<LiveActivityController>((ref) {
  final controller = LiveActivityController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Mirrors the open terminal sessions into an iOS Live Activity (Dynamic
/// Island + Lock Screen). A no-op on other platforms.
class LiveActivityController {
  LiveActivityController(this._ref) {
    if (!_supported) return;
    final sessions = _ref.read(sessionControllerProvider.notifier);
    sessions.onCommandCaptured = schedule;
    _ref.listen(sessionControllerProvider, (_, __) => schedule());
    _ref.listen(settingsControllerProvider, (previous, next) {
      if (previous?.liveActivityEnabled != next.liveActivityEnabled ||
          previous?.liveActivityShowCommand != next.liveActivityShowCommand ||
          previous?.language != next.language) {
        schedule();
      }
    });
    // Clears an activity left over from a previous launch.
    schedule();
  }

  static const _channel = MethodChannel('app.netcatty.mobile/live_activity');

  /// Activities are marked stale after this long without an update, so an
  /// app killed in the background stops claiming a live connection.
  static const _refreshInterval = Duration(minutes: 4);

  final Ref _ref;
  Timer? _debounce;
  Timer? _refresh;
  String? _lastSent;
  bool _sentEnd = false;
  bool _disposed = false;

  bool get _supported => !kIsWeb && Platform.isIOS;

  void schedule() {
    if (_disposed || !_supported) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _sync);
  }

  Future<void> _sync({bool force = false}) async {
    if (_disposed) return;
    final sessions = _ref.read(sessionControllerProvider);
    final settings = _ref.read(settingsControllerProvider);
    final payload = buildLiveActivityPayload(
      sessions: sessions,
      settings: settings,
      lastCommandFor:
          _ref.read(sessionControllerProvider.notifier).lastCommandFor,
      english: settings.language == 'en',
    );
    try {
      if (payload == null) {
        _refresh?.cancel();
        _refresh = null;
        _lastSent = null;
        if (_sentEnd) return;
        _sentEnd = true;
        await _channel.invokeMethod<void>('end');
        return;
      }
      _sentEnd = false;
      _refresh ??= Timer.periodic(
        _refreshInterval,
        (_) => unawaited(_sync(force: true)),
      );
      final encoded = jsonEncode(payload);
      if (!force && encoded == _lastSent) return;
      _lastSent = encoded;
      await _channel.invokeMethod<void>('sync', payload);
    } on MissingPluginException {
      // Older iOS builds without the widget extension.
    } on PlatformException {
      // ActivityKit refused (disabled in Settings, or requested while the app
      // was in the background); the next change retries.
      _lastSent = null;
    }
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _refresh?.cancel();
  }
}
