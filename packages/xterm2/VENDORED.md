# Vendored xterm2

Source: xterm2 5.2.0 (https://github.com/SoFluffyOS/xterm2, tag `5.2.0`), MIT licensed (see LICENSE).

Local change, in `lib/src/ui/custom_text_edit.dart`:

- The hidden platform text field is no longer reset after every keystroke.
  Each update is diffed against the last committed text instead, and the field
  is only reset when the delete-detection padding is used up, the text grows
  past 128 characters, or the caret leaves the end. Resetting on every key made
  iOS keyboards rebuild their suggestion / candidate bar on each keystroke.

To upgrade: copy the new release's `lib/`, `LICENSE` and `pubspec.yaml` here and
re-apply the change above.
