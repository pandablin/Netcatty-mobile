import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/live_activity_controller.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ssh/shell_command_capture.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:xterm2/xterm.dart';

ActiveTerminalSession _session(String id, String label, {String? distro}) =>
    ActiveTerminalSession(
      id: id,
      host: HostProfile({
        'id': id,
        'label': label,
        'hostname': '$id.example.invalid',
        'username': 'root',
        if (distro != null) 'distro': distro,
      }),
      terminal: Terminal(),
      verifyHostKey: (_, __, ___) async => true,
      keyboardInteractive: null,
    );

void main() {
  group('commandFromPromptLine', () {
    test('reads the command after common prompts', () {
      expect(commandFromPromptLine('root@jp:~# ping 45.153.247.231'),
          'ping 45.153.247.231');
      expect(commandFromPromptLine('demo@box:~/src\$ git status'),
          'git status');
      expect(commandFromPromptLine('[root@centos ~]# top'), 'top');
      expect(commandFromPromptLine('~/code ❯ ls -la'), 'ls -la');
      expect(commandFromPromptLine('host% make'), 'make');
    });

    test('keeps redirections inside the command', () {
      expect(commandFromPromptLine('root@jp:~# echo a > b.txt'),
          'echo a > b.txt');
    });

    test('ignores password prompts and empty commands', () {
      expect(commandFromPromptLine('[sudo] password for demo:'), isNull);
      expect(commandFromPromptLine('root@jp:~# '), isNull);
      expect(commandFromPromptLine(''), isNull);
    });

    test('truncates very long commands', () {
      final command = commandFromPromptLine('\$ ${'x' * 400}')!;
      expect(command.length, maxCapturedCommandLength);
      expect(command.endsWith('…'), isTrue);
    });
  });

  group('captureShellCommand', () {
    test('reads the cursor line, including soft-wrapped rows', () {
      final terminal = Terminal()..resize(20, 5);
      terminal.write('root@jp:~# ping 45.153.247.231');
      expect(captureShellCommand(terminal), 'ping 45.153.247.231');
    });

    test('skips full-screen programs on the alternate buffer', () {
      final terminal = Terminal();
      terminal.write('\x1b[?1049h');
      terminal.write('root@jp:~# :wq');
      expect(captureShellCommand(terminal), isNull);
    });
  });

  group('buildLiveActivityPayload', () {
    test('is null without sessions or when disabled', () {
      expect(
        buildLiveActivityPayload(
          sessions: const SessionState(),
          settings: const AppSettings(),
          lastCommandFor: (_) => null,
          english: false,
        ),
        isNull,
      );
      final sessions = SessionState(sessions: [_session('a', 'Aws-JP')]);
      expect(
        buildLiveActivityPayload(
          sessions: sessions,
          settings: const AppSettings(liveActivityEnabled: false),
          lastCommandFor: (_) => 'ls',
          english: false,
        ),
        isNull,
      );
    });

    test('puts the active session first and hides commands on request', () {
      final first = _session('a', 'Aws-JP', distro: 'ubuntu');
      final second = _session('b', 'Debian-HK', distro: 'debian');
      final state = SessionState(sessions: [first, second], activeIndex: 1);
      final payload = buildLiveActivityPayload(
        sessions: state,
        settings: const AppSettings(),
        lastCommandFor: (id) => id == 'b' ? 'ping 1.1.1.1' : null,
        english: true,
      )!;
      expect(payload['activeName'], 'Debian-HK');
      expect(payload['activeDistro'], 'debian');
      expect(payload['activeAddress'], 'root@b.example.invalid');
      expect(payload['command'], 'ping 1.1.1.1');
      expect(payload['count'], 2);
      expect(payload['lang'], 'en');
      final listed = payload['sessions']! as List;
      expect((listed.first as Map)['name'], 'Debian-HK');
      expect((listed.last as Map)['distro'], 'ubuntu');

      final hidden = buildLiveActivityPayload(
        sessions: state,
        settings: const AppSettings(liveActivityShowCommand: false),
        lastCommandFor: (_) => 'ping 1.1.1.1',
        english: false,
      )!;
      expect(hidden['command'], '');
    });
  });
}
