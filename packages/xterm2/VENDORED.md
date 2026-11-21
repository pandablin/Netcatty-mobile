# Vendored xterm2

Source: xterm2 5.2.0 (https://github.com/SoFluffyOS/xterm2, tag `5.2.0`), MIT licensed (see LICENSE).

Local change: an opt-in `keepImeContext` flag on `TerminalView` / `CustomTextEdit`
(off by default, which keeps the upstream behaviour unchanged).

With the flag on, the hidden platform text field keeps the word being typed
instead of being reset after every key, so keyboards show stable suggestions.
Each committed update is diffed against the previous committed text and sent
as deletes plus inserted text. The field is reset only when deleting runs past
the start or after a line is submitted; resetting it elsewhere desynchronises
keyboards that keep their own copy of the text.

To upgrade: copy the new release's `lib/`, `LICENSE` and `pubspec.yaml` here and
re-apply the change in `lib/src/ui/custom_text_edit.dart` and
`lib/src/terminal_view.dart`.
