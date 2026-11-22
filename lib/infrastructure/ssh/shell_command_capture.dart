import 'package:xterm2/xterm.dart';

/// Longest command text kept for the iOS Live Activity.
const maxCapturedCommandLength = 160;

final _promptEnd = RegExp(r'[$#%>❯»]\s');

/// Returns the command typed after a shell prompt on [line], or null when the
/// line does not look like a prompt (password prompts, REPLs without a known
/// prompt marker, blank lines).
///
/// The first prompt marker wins so that redirections inside the command
/// (`echo a > b`) are kept: `root@host:~# echo a > b` → `echo a > b`.
String? commandFromPromptLine(String line) {
  final match = _promptEnd.firstMatch(line);
  if (match == null) return null;
  final command = line.substring(match.end).trim();
  if (command.isEmpty) return null;
  if (command.length <= maxCapturedCommandLength) return command;
  return '${command.substring(0, maxCapturedCommandLength - 1)}…';
}

/// Reads the shell command on the cursor line just before Enter is sent, so
/// tab completion and history recall are reflected exactly as the shell shows
/// them. Full-screen programs (vim, htop, less) use the alternate buffer and
/// are ignored.
String? captureShellCommand(Terminal terminal) {
  final buffer = terminal.buffer;
  if (buffer.isAltBuffer) return null;
  var y = buffer.absoluteCursorY;
  final lines = buffer.lines;
  if (y < 0 || y >= lines.length) return null;
  final parts = <String>[lines[y].getText()];
  // A long command soft-wraps onto several rows; stitch them back together.
  while (y > 0 && lines[y].isWrapped && parts.length < 8) {
    y--;
    parts.insert(0, lines[y].getText());
  }
  return commandFromPromptLine(parts.join().trimRight());
}
