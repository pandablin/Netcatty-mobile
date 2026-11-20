import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import '../../domain/models/host.dart';
import '../../domain/models/server_stats.dart';
import 'server_monitor_service.dart';
import 'ssh_identity.dart';
import 'terminal_input_filter.dart';

export 'ssh_identity.dart' show KeyPassphraseHandler, SshKeyException;

typedef HostKeyVerifier = Future<bool> Function(
  HostProfile host,
  String algorithm,
  String fingerprint,
);

typedef KeyboardInteractiveHandler = Future<List<String>?> Function(
  String name,
  String instruction,
  List<({String text, bool echo})> prompts,
);

class ConnectionCancelledException implements Exception {
  const ConnectionCancelledException();

  @override
  String toString() => '连接已由用户终止';
}

/// Applies one-shot toolbar modifiers to the next system-keyboard input.
/// This bridges Flutter's soft keyboard and the terminal toolbar, which do
/// not share hardware modifier state on Android or iOS.
class TerminalInputController extends ChangeNotifier {
  Set<String> modifiers = const {};

  void setModifiers(Iterable<String> value) {
    final next = Set<String>.unmodifiable(value);
    if (setEquals(next, modifiers)) return;
    modifiers = next;
    notifyListeners();
  }

  void clearModifiers() => setModifiers(const {});

  String consume(String value) {
    final active = modifiers;
    if (active.isEmpty || value.isEmpty) return value;
    modifiers = const {};
    notifyListeners();
    final shift = active.contains('shift');
    final alt = active.contains('alt');
    final ctrl = active.contains('ctrl');
    final parameter = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0);
    var result = value;
    if (result.length == 3 &&
        result.startsWith('\x1b[') &&
        'ABCDHF'.contains(result[2])) {
      result = '\x1b[1;$parameter${result[2]}';
    } else {
      if (shift && result.length == 1) result = result.toUpperCase();
      if (ctrl && result.length == 1) {
        final code = result.toUpperCase().codeUnitAt(0);
        if (code >= 64 && code <= 95) {
          result = String.fromCharCode(code & 0x1f);
        }
      }
      if (alt) result = '\x1b$result';
    }
    return result;
  }
}

class ActiveTerminalSession {
  ActiveTerminalSession({
    required this.id,
    required this.host,
    required this.terminal,
    required this.verifyHostKey,
    required this.keyboardInteractive,
    TerminalInputController? input,
    this.sshClients = const [],
    this.sshSession,
    this.telnetSocket,
  }) : input = input ?? TerminalInputController();

  final String id;
  final HostProfile host;
  final Terminal terminal;
  final HostKeyVerifier verifyHostKey;
  final KeyboardInteractiveHandler? keyboardInteractive;
  final TerminalInputController input;
  final List<SSHClient> sshClients;
  final SSHSession? sshSession;
  final Socket? telnetSocket;
  bool connected = true;
  bool closedByUser = false;
  ServerSystemInfo? systemInfo;
  SessionMonitor? monitor;

  SSHClient? get sshClient => sshClients.isEmpty ? null : sshClients.last;
  bool get isSsh => sshClient != null;
  Future<void> get done =>
      sshSession?.done ?? telnetSocket?.done ?? Future.value();

  Future<void> ping({Duration timeout = const Duration(seconds: 8)}) async {
    if (!connected) throw StateError('SSH session is disconnected');
    if (sshClients.isNotEmpty) {
      await Future.wait(sshClients.map((client) => client.ping()))
          .timeout(timeout);
      return;
    }
    await telnetSocket?.flush().timeout(timeout);
  }

  void abort() {
    monitor?.stop();
    connected = false;
    sshSession?.close();
    for (final client in sshClients.reversed) {
      client.close();
    }
    telnetSocket?.destroy();
  }

  Future<void> close() async {
    monitor?.stop();
    closedByUser = true;
    connected = false;
    sshSession?.close();
    for (final client in sshClients.reversed) {
      client.close();
    }
    await telnetSocket?.close();
    input.dispose();
  }
}

class SshService {
  final _pendingConnections = <String, _PendingConnection>{};

  /// Key passphrases typed during this app session, by key id. Memory only:
  /// lets reconnects, managed terminals and new tabs reuse an unlocked key.
  final _keyPassphrases = <String, String>{};

  void cancelConnection(String sessionId) {
    _pendingConnections[sessionId]?.cancel();
  }

  Future<ActiveTerminalSession> connect({
    required String sessionId,
    required HostProfile host,
    required List<HostProfile> hosts,
    required List<SshKeyProfile> keys,
    required List<ProxyProfile> proxyProfiles,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    KeyPassphraseHandler? requestPassphrase,
    Terminal? terminal,
  }) async {
    _pendingConnections.remove(sessionId)?.cancel();
    final pending = _PendingConnection();
    _pendingConnections[sessionId] = pending;
    try {
      if (host.protocol == HostProtocol.telnet) {
        return await _connectTelnet(
          sessionId,
          host,
          verifyHostKey,
          keyboardInteractive,
          terminal,
          pending,
        );
      }
      if (host.protocol == HostProtocol.mosh) {
        throw UnsupportedError('Mosh 需要平台原生 UDP 运行时，当前版本尚未启用。');
      }

      final chain = _resolveHostChain(host, hosts);
      final route = [...chain, host];
      // Unlock keys before opening any socket: a passphrase prompt must not
      // race the server's authentication timeout.
      final identities = <List<SSHKeyPair>?>[];
      for (final current in route) {
        identities.add(
          current.authMethod == HostAuthMethod.password
              ? null
              : await pending.waitFor(
                  loadHostIdentities(
                    current,
                    keys,
                    requestPassphrase: requestPassphrase,
                    passphraseCache: _keyPassphrases,
                  ),
                ),
        );
      }
      final clients = <SSHClient>[];
      SSHSocket? transport;
      try {
        for (var index = 0; index < route.length; index++) {
          final current = route[index];
          final activeTransport = transport ??
              await pending.waitFor<SSHSocket>(
                _openTransport(
                  current,
                  proxyProfiles,
                  timeout: _connectTimeout(current),
                ),
                onCancelled: (socket) => socket.destroy(),
              );
          transport = activeTransport;
          pending.transport = activeTransport;
          pending.throwIfCancelled();
          final client = _createClient(
            activeTransport,
            current,
            identities[index],
            verifyHostKey,
            keyboardInteractive,
          );
          clients.add(client);
          pending.clients.add(client);
          pending.throwIfCancelled();
          if (index < route.length - 1) {
            final next = route[index + 1];
            transport = await pending.waitFor<SSHForwardChannel>(
              client.forwardLocal(bareHostname(next.hostname), next.port),
              onCancelled: (socket) => socket.destroy(),
            );
            pending.transport = transport;
          }
        }

        final client = clients.last;
        final session = await pending.waitFor(
          client.shell(
            pty: const SSHPtyConfig(
                type: 'xterm-256color', width: 80, height: 24),
            environment: _environment(host),
          ),
          onCancelled: (value) => value.close(),
        );
        final output = terminal ?? Terminal(maxLines: 10000);
        final input = TerminalInputController();
        final sink = bindTerminalOutput(
          input,
          (value) => session.write(Uint8List.fromList(utf8.encode(value))),
        );
        output.onOutput = sink.write;
        output.onResize = (width, height, pixelWidth, pixelHeight) {
          session.resizeTerminal(width, height, pixelWidth, pixelHeight);
        };
        // Decode as a stream: a multi-byte character (CJK text, emoji, box
        // drawing) split across two SSH packets used to render as U+FFFD.
        const Utf8Decoder(allowMalformed: true)
            .bind(session.stdout)
            .listen(output.write);
        const Utf8Decoder(allowMalformed: true)
            .bind(session.stderr)
            .listen(output.write);
        final startup = host.startupCommand;
        if (startup != null && startup.isNotEmpty) {
          session.write(Uint8List.fromList(utf8.encode('$startup\n')));
        }
        return ActiveTerminalSession(
          id: sessionId,
          host: host,
          terminal: output,
          verifyHostKey: verifyHostKey,
          keyboardInteractive: keyboardInteractive,
          input: input,
          sshClients: clients,
          sshSession: session,
        );
      } catch (_) {
        for (final client in clients.reversed) {
          client.close();
        }
        rethrow;
      }
    } finally {
      if (identical(_pendingConnections[sessionId], pending)) {
        _pendingConnections.remove(sessionId);
      }
    }
  }

  SSHClient _createClient(
    SSHSocket socket,
    HostProfile host,
    List<SSHKeyPair>? identities,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  ) {
    return SSHClient(
      socket,
      username: host.username,
      identities:
          host.authMethod == HostAuthMethod.password ? null : identities,
      onPasswordRequest:
          host.authMethod == HostAuthMethod.key || host.password == null
              ? null
              : () => host.password,
      onUserInfoRequest: (request) async {
        if (keyboardInteractive != null) {
          return keyboardInteractive(
            request.name,
            request.instruction,
            request.prompts
                .map((prompt) => (text: prompt.promptText, echo: prompt.echo))
                .toList(),
          );
        }
        return request.prompts
            .map((prompt) => prompt.echo ? '' : (host.password ?? ''))
            .toList();
      },
      keepAliveInterval: Duration(
        seconds: (host.data['keepaliveInterval'] as num?)?.toInt() ?? 10,
      ),
      authTimeout: Duration(
        seconds:
            (host.data['sshAuthReadyTimeoutSeconds'] as num?)?.toInt() ?? 30,
      ),
      onVerifyHostKey: (type, fingerprint) => verifyHostKey(
        host,
        type,
        utf8.decode(fingerprint),
      ),
    );
  }

  List<HostProfile> _resolveHostChain(
    HostProfile target,
    List<HostProfile> hosts,
  ) {
    final byId = {for (final host in hosts) host.id: host};
    final seen = <String>{target.id};
    final result = <HostProfile>[];
    for (final id in target.hostChainIds) {
      final jump = byId[id];
      if (jump == null) throw StateError('找不到跳板机：$id');
      if (!seen.add(jump.id)) throw StateError('跳板机链路存在循环');
      if (jump.protocol != HostProtocol.ssh) {
        throw StateError('跳板机必须使用 SSH：${jump.label}');
      }
      result.add(jump);
    }
    return result;
  }

  Duration _connectTimeout(HostProfile host) => Duration(
        seconds:
            (host.data['sshTcpConnectTimeoutSeconds'] as num?)?.toInt() ?? 15,
      );

  Map<String, String> _environment(HostProfile host) {
    final result = <String, String>{};
    for (final value
        in host.data['environmentVariables'] as List? ?? const []) {
      if (value is Map && value['name'] != null) {
        result[value['name'].toString()] = value['value']?.toString() ?? '';
      }
    }
    return result;
  }

  ProxyConfig? _effectiveProxy(
    HostProfile host,
    List<ProxyProfile> profiles,
  ) {
    final profileId = host.proxyProfileId;
    if (profileId != null && profileId.isNotEmpty) {
      for (final profile in profiles) {
        if (profile.id == profileId) return profile.config;
      }
      throw StateError('找不到代理配置：$profileId');
    }
    return host.proxyConfig;
  }

  Future<SSHSocket> _openTransport(
    HostProfile host,
    List<ProxyProfile> profiles, {
    required Duration timeout,
  }) async {
    final proxy = _effectiveProxy(host, profiles);
    if (proxy == null || proxy.host.isEmpty || proxy.port <= 0) {
      return SSHSocket.connect(
        bareHostname(host.hostname),
        host.port,
        timeout: timeout,
      );
    }
    final socket = await Socket.connect(
      bareHostname(proxy.host),
      proxy.port,
      timeout: timeout,
    );
    final cursor = _SocketCursor(socket);
    try {
      switch (proxy.type) {
        case ProxyType.http:
          await _connectHttpProxy(socket, cursor, proxy, host);
        case ProxyType.socks5:
          await _connectSocksProxy(socket, cursor, proxy, host);
      }
      return _ProxySshSocket(socket, cursor);
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }

  Future<void> _connectHttpProxy(
    Socket socket,
    _SocketCursor cursor,
    ProxyConfig proxy,
    HostProfile target,
  ) async {
    final authority = hostAuthority(target.hostname, target.port);
    final auth = proxy.username?.isNotEmpty == true
        ? 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('${proxy.username}:${proxy.password ?? ''}'))}\r\n'
        : '';
    socket.write(
      'CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n$auth'
      'Proxy-Connection: keep-alive\r\n\r\n',
    );
    await socket.flush();
    final header = utf8.decode(
      await cursor.readUntil(const [13, 10, 13, 10], maxLength: 32768),
      allowMalformed: true,
    );
    final match = RegExp(r'^HTTP/\d(?:\.\d)?\s+(\d{3})').firstMatch(header);
    if (match == null || match.group(1) != '200') {
      throw SocketException('HTTP 代理连接失败：${header.split('\r\n').first}');
    }
  }

  Future<void> _connectSocksProxy(
    Socket socket,
    _SocketCursor cursor,
    ProxyConfig proxy,
    HostProfile target,
  ) async {
    final hasAuth = proxy.username?.isNotEmpty == true;
    socket.add(hasAuth ? [5, 2, 0, 2] : [5, 1, 0]);
    await socket.flush();
    final greeting = await cursor.readExact(2);
    if (greeting[0] != 5 || greeting[1] == 255) {
      throw const SocketException('SOCKS5 代理拒绝认证方式');
    }
    if (greeting[1] == 2) {
      final user = utf8.encode(proxy.username ?? '');
      final pass = utf8.encode(proxy.password ?? '');
      if (user.length > 255 || pass.length > 255) {
        throw const SocketException('SOCKS5 代理用户名或密码过长');
      }
      socket.add([1, user.length, ...user, pass.length, ...pass]);
      await socket.flush();
      final auth = await cursor.readExact(2);
      if (auth[1] != 0) throw const SocketException('SOCKS5 代理认证失败');
    } else if (greeting[1] != 0) {
      throw const SocketException('SOCKS5 代理认证方式不受支持');
    }
    socket.add([
      5,
      1,
      0,
      ...socksAddress(target.hostname),
      target.port >> 8,
      target.port & 0xff,
    ]);
    await socket.flush();
    final reply = await cursor.readExact(4);
    if (reply[0] != 5 || reply[1] != 0) {
      throw SocketException('SOCKS5 代理连接失败，状态码 ${reply[1]}');
    }
    final addressLength = switch (reply[3]) {
      1 => 4,
      3 => (await cursor.readExact(1)).first,
      4 => 16,
      _ => throw const SocketException('SOCKS5 返回了未知地址类型'),
    };
    await cursor.readExact(addressLength + 2);
  }

  Future<ActiveTerminalSession> _connectTelnet(
    String sessionId,
    HostProfile host,
    HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
    Terminal? existingTerminal,
    _PendingConnection pending,
  ) async {
    final socket = await pending.waitFor(
      Socket.connect(
        bareHostname(host.hostname),
        host.port,
        timeout: const Duration(seconds: 15),
      ),
      onCancelled: (value) => value.destroy(),
    );
    pending.telnetSocket = socket;
    pending.throwIfCancelled();
    final terminal = existingTerminal ?? Terminal(maxLines: 10000);
    final input = TerminalInputController();
    final sink = bindTerminalOutput(
      input,
      (value) => socket.add(utf8.encode(value)),
    );
    terminal.onOutput = sink.write;
    final telnet = TelnetStreamFilter();
    final text = const Utf8Decoder(allowMalformed: true)
        .startChunkedConversion(_TextCallbackSink(terminal.write));
    socket.listen(
      (bytes) {
        final visible = telnet.process(bytes, socket.add);
        if (visible.isNotEmpty) text.add(visible);
      },
      onDone: text.close,
    );
    return ActiveTerminalSession(
      id: sessionId,
      host: host,
      terminal: terminal,
      verifyHostKey: verifyHostKey,
      keyboardInteractive: keyboardInteractive,
      input: input,
      telnetSocket: socket,
    );
  }
}

/// Strips the square brackets users often type around IPv6 literals
/// (`[2001:db8::1]`), which `Socket.connect` cannot resolve.
String bareHostname(String hostname) {
  final value = hostname.trim();
  if (value.length > 2 && value.startsWith('[') && value.endsWith(']')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

/// `host:port` for an HTTP CONNECT request line, bracketing IPv6 literals as
/// RFC 7230 requires (`[2001:db8::1]:22`).
String hostAuthority(String hostname, int port) {
  final host = bareHostname(hostname);
  return host.contains(':') ? '[$host]:$port' : '$host:$port';
}

/// SOCKS5 ATYP + DST.ADDR for [hostname]: IP literals are sent as IPv4/IPv6
/// addresses (some proxies refuse IPv6 literals in the domain-name form).
List<int> socksAddress(String hostname) {
  final host = bareHostname(hostname);
  final address = InternetAddress.tryParse(host);
  if (address != null) {
    return [
      address.type == InternetAddressType.IPv6 ? 4 : 1,
      ...address.rawAddress,
    ];
  }
  final domain = utf8.encode(host);
  if (domain.isEmpty || domain.length > 255) {
    throw const SocketException('目标主机名无效或过长');
  }
  return [3, domain.length, ...domain];
}

/// Strips Telnet commands from a byte stream and refuses every option the
/// server offers or requests. Keeps state between chunks, so a command split
/// across two TCP reads is neither shown on screen nor misparsed, handles
/// escaped 0xFF data bytes and subnegotiation blocks, and never answers
/// DONT/WONT, which RFC 854 forbids because it can loop forever.
class TelnetStreamFilter {
  static const _iac = 255;
  static const _dont = 254;
  static const _do = 253;
  static const _wont = 252;
  static const _will = 251;
  static const _sb = 250;
  static const _se = 240;

  var _state = _TelnetState.data;
  var _command = 0;

  List<int> process(List<int> bytes, void Function(List<int> reply) reply) {
    final visible = <int>[];
    for (final byte in bytes) {
      switch (_state) {
        case _TelnetState.data:
          if (byte == _iac) {
            _state = _TelnetState.command;
          } else {
            visible.add(byte);
          }
        case _TelnetState.command:
          if (byte == _iac) {
            visible.add(_iac);
            _state = _TelnetState.data;
          } else if (byte >= _will && byte <= _dont) {
            _command = byte;
            _state = _TelnetState.option;
          } else if (byte == _sb) {
            _state = _TelnetState.subnegotiation;
          } else {
            _state = _TelnetState.data;
          }
        case _TelnetState.option:
          if (_command == _do) reply([_iac, _wont, byte]);
          if (_command == _will) reply([_iac, _dont, byte]);
          _state = _TelnetState.data;
        case _TelnetState.subnegotiation:
          if (byte == _iac) _state = _TelnetState.subnegotiationIac;
        case _TelnetState.subnegotiationIac:
          _state = byte == _se
              ? _TelnetState.data
              : _TelnetState.subnegotiation;
      }
    }
    return visible;
  }
}

enum _TelnetState {
  data,
  command,
  option,
  subnegotiation,
  subnegotiationIac,
}

class _TextCallbackSink implements Sink<String> {
  _TextCallbackSink(this._onText);

  final void Function(String text) _onText;

  @override
  void add(String data) {
    if (data.isNotEmpty) _onText(data);
  }

  @override
  void close() {}
}

const _connectionCancelledMarker = Object();

class _PendingConnectionResult<T> {
  const _PendingConnectionResult(this.value);
  final T value;
}

class _PendingConnection {
  final cancelled = Completer<void>();
  final clients = <SSHClient>[];
  SSHSocket? transport;
  Socket? telnetSocket;

  bool get isCancelled => cancelled.isCompleted;

  void cancel() {
    if (cancelled.isCompleted) return;
    cancelled.complete();
    telnetSocket?.destroy();
    transport?.destroy();
    for (final client in clients.reversed) {
      client.close();
    }
  }

  void throwIfCancelled() {
    if (isCancelled) throw const ConnectionCancelledException();
  }

  Future<T> waitFor<T>(
    Future<T> operation, {
    void Function(T value)? onCancelled,
  }) async {
    throwIfCancelled();
    final winner = await Future.any<Object>([
      operation.then<Object>(_PendingConnectionResult<T>.new),
      cancelled.future.then<Object>((_) => _connectionCancelledMarker),
    ]);
    if (identical(winner, _connectionCancelledMarker)) {
      unawaited(
        operation.then<void>((value) {
          onCancelled?.call(value);
        }).catchError((Object _) {}),
      );
      throw const ConnectionCancelledException();
    }
    return (winner as _PendingConnectionResult<T>).value;
  }
}

class _SocketCursor {
  _SocketCursor(Socket socket) : _iterator = StreamIterator(socket);

  final StreamIterator<Uint8List> _iterator;
  final List<int> _buffer = [];

  Future<List<int>> readExact(int length) async {
    await _fill(length);
    final result = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return result;
  }

  Future<List<int>> readUntil(
    List<int> marker, {
    required int maxLength,
  }) async {
    while (true) {
      final index = _indexOf(_buffer, marker);
      if (index >= 0) {
        final end = index + marker.length;
        final result = _buffer.sublist(0, end);
        _buffer.removeRange(0, end);
        return result;
      }
      if (_buffer.length >= maxLength) {
        throw const SocketException('代理响应头过长');
      }
      if (!await _iterator.moveNext()) {
        throw const SocketException('代理在握手完成前关闭了连接');
      }
      _buffer.addAll(_iterator.current);
    }
  }

  Future<void> _fill(int length) async {
    while (_buffer.length < length) {
      if (!await _iterator.moveNext()) {
        throw const SocketException('代理在握手完成前关闭了连接');
      }
      _buffer.addAll(_iterator.current);
    }
  }

  Stream<Uint8List> remainingStream() async* {
    if (_buffer.isNotEmpty) {
      yield Uint8List.fromList(_buffer);
      _buffer.clear();
    }
    while (await _iterator.moveNext()) {
      yield _iterator.current;
    }
  }

  static int _indexOf(List<int> source, List<int> marker) {
    for (var index = 0; index <= source.length - marker.length; index++) {
      var matches = true;
      for (var offset = 0; offset < marker.length; offset++) {
        if (source[index + offset] != marker[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) return index;
    }
    return -1;
  }
}

class _ProxySshSocket implements SSHSocket {
  _ProxySshSocket(this._socket, this._cursor);

  final Socket _socket;
  final _SocketCursor _cursor;

  @override
  Stream<Uint8List> get stream => _cursor.remainingStream();

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}
