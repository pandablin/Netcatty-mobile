part of 'terminal_screen.dart';

class _ConnectionStatusPane extends StatelessWidget {
  const _ConnectionStatusPane({
    required this.pending,
    this.onReturn,
    this.onClose,
    this.onCancel,
  });

  final PendingTerminalConnection pending;
  final VoidCallback? onReturn;
  final VoidCallback? onClose;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = pending.phase == PendingConnectionPhase.failed;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              key: const ValueKey('terminal-connection-status-dialog'),
              elevation: 12,
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HostSystemIcon(host: pending.host, size: 50),
                    const SizedBox(height: 12),
                    LText(
                      pending.host.label,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    LText(
                      '${pending.host.protocol.name.toUpperCase()}  '
                      '${pending.host.username}@${pending.host.hostname}:'
                      '${pending.host.port}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 20),
                    if (failed)
                      Icon(
                        Icons.error_outline,
                        size: 38,
                        color: scheme.error,
                      )
                    else ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 18),
                    ],
                    LText(
                      failed ? '安全连接建立失败' : '正在建立安全连接…',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: failed ? scheme.error : null,
                          ),
                    ),
                    if (failed) ...[
                      const SizedBox(height: 8),
                      LText(
                        '${pending.error ?? '未知错误'}',
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                    if (onReturn != null ||
                        onClose != null ||
                        onCancel != null) ...[
                      const SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (onReturn != null)
                            TextButton.icon(
                              onPressed: onReturn,
                              icon: const Icon(Icons.arrow_back),
                              label: const LText('返回当前终端'),
                            ),
                          if (onClose != null)
                            FilledButton.icon(
                              onPressed: onClose,
                              icon: const Icon(Icons.close),
                              label: const LText('关闭标签页'),
                            ),
                          if (onCancel != null)
                            FilledButton.icon(
                              key: const ValueKey('cancel-pending-connection'),
                              onPressed: onCancel,
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const LText('终止连接'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalPictureInPictureHeader extends StatelessWidget {
  const _TerminalPictureInPictureHeader({required this.session});

  final ActiveTerminalSession session;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SizedBox(
          height: 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: session.connected
                      ? Colors.greenAccent
                      : Colors.orangeAccent,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: LText(
                    session.host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const Icon(Icons.picture_in_picture, size: 15),
              ],
            ),
          ),
        ),
      );
}

/// Connects the toolbar keyboard button with the terminal pane that owns
/// keyboard input (the active tab), which lives deeper in the widget tree.
class _TerminalKeyboardBridge {
  final open = ValueNotifier<bool>(false);
  Object? _owner;
  VoidCallback? _show;
  bool _disposed = false;

  void attach(Object owner, VoidCallback show, {required bool focused}) {
    _owner = owner;
    _show = show;
    _publish(focused);
  }

  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _show = null;
    _publish(false);
  }

  void report(Object owner, bool focused) {
    if (identical(_owner, owner)) _publish(focused);
  }

  void show() => _show?.call();

  /// Panes attach and detach while the tree is building or being finalized,
  /// where rebuilding the toolbar is not allowed, so publish afterwards.
  void _publish(bool focused) {
    scheduleMicrotask(() {
      if (!_disposed) open.value = focused;
    });
  }

  void dispose() {
    _disposed = true;
    open.dispose();
  }
}

class _TerminalPane extends StatefulWidget {
  const _TerminalPane({
    super.key,
    required this.session,
    required this.fontSize,
    required this.secureKeyboard,
    required this.pictureInPicture,
    required this.transparentBackground,
    this.tapToKeyboard = true,
    this.imeSuggestions = false,
    this.keyboard,
  });
  final ActiveTerminalSession session;
  final double fontSize;
  final bool secureKeyboard;
  final bool pictureInPicture;
  final bool transparentBackground;

  /// Whether a tap may open the soft keyboard (setting, upstream #36).
  final bool tapToKeyboard;

  /// Experimental keyboard-suggestion mode (setting).
  final bool imeSuggestions;

  /// Set only on the pane that receives toolbar keyboard requests.
  final _TerminalKeyboardBridge? keyboard;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  final _controller = TerminalController(
    pointerInputs: const PointerInputs({PointerInput.scroll}),
  );
  var _terminalViewKey = GlobalKey<TerminalViewState>();
  final _terminalStackKey = GlobalKey();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode(debugLabel: 'terminal');
  Offset? _dragPointerToAnchor;
  Timer? _pictureInPictureUpdateTimer;
  Timer? _copyHoldTimer;
  Offset? _copyHoldOrigin;
  bool _copySnapshotOpen = false;
  late bool _alternateScreen;

  @override
  void initState() {
    super.initState();
    _alternateScreen = widget.session.terminal.isUsingAltBuffer;
    widget.session.terminal.addListener(_onTerminalChanged);
    _focusNode.addListener(_onFocusChanged);
    widget.keyboard?.attach(this, _showKeyboard, focused: _focusNode.hasFocus);
    if (widget.pictureInPicture) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendPipUpdate());
    }
  }

  @override
  void didUpdateWidget(covariant _TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.secureKeyboard != widget.secureKeyboard ||
        oldWidget.imeSuggestions != widget.imeSuggestions) {
      // xterm keeps the platform TextInputConnection alive while the view is
      // mounted. Recreate it so Android and iOS receive the new input type.
      _terminalViewKey = GlobalKey<TerminalViewState>();
    }
    if (!identical(oldWidget.keyboard, widget.keyboard)) {
      oldWidget.keyboard?.detach(this);
      widget.keyboard
          ?.attach(this, _showKeyboard, focused: _focusNode.hasFocus);
    }
    if (oldWidget.session.terminal != widget.session.terminal) {
      oldWidget.session.terminal.removeListener(_onTerminalChanged);
      widget.session.terminal.addListener(_onTerminalChanged);
    }
    if (!oldWidget.pictureInPicture && widget.pictureInPicture) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendPipUpdate());
    } else if (oldWidget.pictureInPicture && !widget.pictureInPicture) {
      _pictureInPictureUpdateTimer?.cancel();
      _pictureInPictureUpdateTimer = null;
    }
  }

  @override
  void dispose() {
    widget.session.terminal.removeListener(_onTerminalChanged);
    widget.keyboard?.detach(this);
    _pictureInPictureUpdateTimer?.cancel();
    _copyHoldTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onFocusChanged() => widget.keyboard?.report(this, _focusNode.hasFocus);

  bool get _scrolledToBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 2;
  }

  /// Decides, before xterm handles the tap, whether this touch may focus the
  /// terminal and raise the keyboard. Raising it also jumps to the bottom,
  /// which made scrolling back to read or copy output frustrating (#36), so
  /// a tap while scrolled up into history never opens it.
  void _gateKeyboardForTap() {
    if (_focusNode.hasFocus) return;
    _focusNode.canRequestFocus = widget.tapToKeyboard && _scrolledToBottom;
  }

  void _showKeyboard() {
    _focusNode.canRequestFocus = true;
    _terminalViewKey.currentState?.requestKeyboard();
  }

  void _onTerminalChanged() {
    final alternate = widget.session.terminal.isUsingAltBuffer;
    if (alternate != _alternateScreen) {
      _copyHoldTimer?.cancel();
      setState(() => _alternateScreen = alternate);
    }
    if (_controller.selection != null &&
        _controller.selectionFor(widget.session.terminal.buffer) == null) {
      _controller.clearSelection();
    }
    if (!widget.pictureInPicture || _pictureInPictureUpdateTimer != null) {
      return;
    }
    _pictureInPictureUpdateTimer = Timer(
      const Duration(seconds: 1),
      () {
        _pictureInPictureUpdateTimer = null;
        _sendPipUpdate();
      },
    );
  }

  void _sendPipUpdate() {
    if (!mounted || !widget.pictureInPicture) return;
    final scheme = Theme.of(context).colorScheme;
    unawaited(
      TerminalPictureInPictureService.update(
        title: widget.session.host.label,
        text: terminalPictureInPictureText(widget.session.terminal),
        connected: widget.session.connected,
        backgroundColor: scheme.surface.toARGB32(),
        foregroundColor: scheme.onSurface.toARGB32(),
        accentColor: scheme.primary.toARGB32(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paneBackground =
        widget.transparentBackground ? Colors.transparent : scheme.surface;
    // Each theme has its own ANSI palette, tuned for its background (light
    // themes need darker yellows and whites to stay readable).
    final ansi = Theme.of(context).extension<TerminalPalette>()?.ansi ??
        NetcattyTheme.presets(Theme.of(context).brightness).first.ansi;
    final terminalTheme = TerminalTheme(
      cursor: scheme.primary,
      selection: scheme.primary.withValues(alpha: 0.35),
      foreground: scheme.onSurface,
      background: scheme.surface,
      black: ansi[0],
      red: ansi[1],
      green: ansi[2],
      yellow: ansi[3],
      blue: ansi[4],
      magenta: ansi[5],
      cyan: ansi[6],
      white: ansi[7],
      brightBlack: ansi[8],
      brightRed: ansi[9],
      brightGreen: ansi[10],
      brightYellow: ansi[11],
      brightBlue: ansi[12],
      brightMagenta: ansi[13],
      brightCyan: ansi[14],
      brightWhite: ansi[15],
      searchHitBackground: scheme.tertiaryContainer,
      searchHitBackgroundCurrent: scheme.primaryContainer,
      searchHitForeground: scheme.onSurface,
    );
    return ColoredBox(
      color: paneBackground,
      child: AnimatedBuilder(
        animation: Listenable.merge([_controller, _scrollController]),
        child: _terminalContent(terminalTheme),
        builder: (context, terminalContent) {
          final selection = _controller
              .selectionFor(widget.session.terminal.buffer)
              ?.normalized;
          final startHandle = selection == null
              ? null
              : _selectionHandlePosition(selection.begin);
          final endHandle = selection == null
              ? null
              : _selectionHandlePosition(selection.end);
          return Stack(
            key: _terminalStackKey,
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              terminalContent!,
              if (!widget.pictureInPicture && startHandle != null)
                _TerminalSelectionHandle(
                  key: const ValueKey('terminal-selection-handle-start'),
                  anchor: startHandle,
                  color: scheme.primary,
                  onPanStart: (details) => _startHandleDrag(true, details),
                  onPanUpdate: (details) => _updateHandleDrag(true, details),
                  onPanEnd: _endHandleDrag,
                ),
              if (!widget.pictureInPicture && endHandle != null)
                _TerminalSelectionHandle(
                  key: const ValueKey('terminal-selection-handle-end'),
                  anchor: endHandle,
                  color: scheme.primary,
                  onPanStart: (details) => _startHandleDrag(false, details),
                  onPanUpdate: (details) => _updateHandleDrag(false, details),
                  onPanEnd: _endHandleDrag,
                ),
              if (!widget.pictureInPicture &&
                  (selection != null || _alternateScreen))
                Positioned(
                  top: 10,
                  right: 10,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('copy-terminal-selection'),
                    onPressed: _alternateScreen
                        ? () => _showCopySnapshot()
                        : _copySelection,
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const LText('复制'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _terminalContent(TerminalTheme theme) => Listener(
        onPointerDown: (event) {
          _gateKeyboardForTap();
          final mouse = event.kind == PointerDeviceKind.mouse;
          // Switching input devices changes policy; repeated finger gestures do not.
          if (_controller.pointerInput.inputs.contains(PointerInput.tap) !=
              mouse) {
            _controller.setPointerInputs(PointerInputs({
              PointerInput.scroll,
              if (mouse) PointerInput.tap,
            }));
          }
          _copyHoldTimer?.cancel();
          if (_alternateScreen &&
              !widget.pictureInPicture &&
              event.kind == PointerDeviceKind.touch) {
            _copyHoldOrigin = event.position;
            // Extract text only after the hold is recognized, never on a swipe.
            _copyHoldTimer =
                Timer(const Duration(milliseconds: 550), _showCopySnapshot);
          }
        },
        onPointerMove: (event) {
          if (_copyHoldOrigin != null &&
              (event.position - _copyHoldOrigin!).distance > kTouchSlop) {
            _copyHoldTimer?.cancel();
            _copyHoldOrigin = null;
          }
        },
        onPointerUp: (_) => _copyHoldTimer?.cancel(),
        onPointerCancel: (_) => _copyHoldTimer?.cancel(),
        child: RepaintBoundary(
          child: _SettledHeight(
            child: TerminalView(
              widget.session.terminal,
              simulateScroll: false,
              key: _terminalViewKey,
              controller: _controller,
              scrollController: _scrollController,
              theme: theme,
              backgroundOpacity: widget.transparentBackground ? 0 : 1,
              keyboardAppearance: Theme.of(context).brightness,
              keyboardType: widget.secureKeyboard
                  ? TextInputType.visiblePassword
                  // The email type made keyboards offer "@qq.com"-style
                  // completions; plain text gives ordinary word suggestions.
                  : widget.imeSuggestions
                      ? TextInputType.text
                      : TextInputType.emailAddress,
              keepImeContext: widget.imeSuggestions && !widget.secureKeyboard,
              deleteDetection: true,
              focusNode: _focusNode,
              autofocus: !widget.pictureInPicture && widget.tapToKeyboard,
              padding: const EdgeInsets.all(8),
              textStyle: TerminalStyle(
                  fontSize: widget.fontSize, fontFamily: 'monospace'),
            ),
          ),
        ),
      );

  Future<void> _showCopySnapshot() async {
    if (!mounted || _copySnapshotOpen) return;
    _copyHoldTimer?.cancel();
    _copySnapshotOpen = true;
    final text = widget.session.terminal.buffer.getText();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _TerminalCopySheet(text: text),
      );
    } finally {
      _copySnapshotOpen = false;
    }
  }

  Offset? _selectionHandlePosition(CellOffset offset) {
    final terminalView = _terminalViewKey.currentState;
    final stackContext = _terminalStackKey.currentContext;
    if (terminalView == null || stackContext == null) return null;
    final stackBox = stackContext.findRenderObject();
    if (stackBox is! RenderBox || !stackBox.hasSize) return null;
    final renderTerminal = terminalView.renderTerminal;
    if (!renderTerminal.attached || !renderTerminal.hasSize) return null;
    final terminalOffset = renderTerminal.getOffset(offset).translate(
          0,
          renderTerminal.cellSize.height,
        );
    final position = stackBox.globalToLocal(
      renderTerminal.localToGlobal(terminalOffset),
    );
    if (position.dy < 0 ||
        position.dy > stackBox.size.height ||
        position.dx < 0 ||
        position.dx > stackBox.size.width) {
      return null;
    }
    return position;
  }

  void _startHandleDrag(bool start, DragStartDetails details) {
    final selection = _controller.selection?.normalized;
    final stackContext = _terminalStackKey.currentContext;
    if (selection == null || stackContext == null) return;
    final stackBox = stackContext.findRenderObject();
    if (stackBox is! RenderBox) return;
    final anchor = _selectionHandlePosition(
      start ? selection.begin : selection.end,
    );
    if (anchor == null) return;
    _dragPointerToAnchor =
        details.globalPosition - stackBox.localToGlobal(anchor);
  }

  void _updateHandleDrag(bool start, DragUpdateDetails details) {
    final pointerToAnchor = _dragPointerToAnchor;
    if (pointerToAnchor == null) return;
    final boundary = _selectionBoundaryAt(
      details.globalPosition - pointerToAnchor,
    );
    final selection = _controller.selection?.normalized;
    if (boundary == null || selection == null) return;

    var begin = selection.begin;
    var end = selection.end;
    if (start) {
      begin = boundary.isAfter(end) ? end : boundary;
    } else {
      end = boundary.isBefore(begin) ? begin : boundary;
    }
    _controller.setSelection(
      widget.session.terminal.buffer.createAnchorFromOffset(begin),
      widget.session.terminal.buffer.createAnchorFromOffset(end),
      mode: _controller.selectionMode,
    );
  }

  CellOffset? _selectionBoundaryAt(Offset globalPosition) {
    final terminalView = _terminalViewKey.currentState;
    if (terminalView == null) return null;
    final renderTerminal = terminalView.renderTerminal;
    if (!renderTerminal.attached || !renderTerminal.hasSize) return null;
    final local = renderTerminal.globalToLocal(globalPosition);
    final origin = renderTerminal.getOffset(const CellOffset(0, 0));
    final cellSize = renderTerminal.cellSize;
    final column = ((local.dx - origin.dx) / cellSize.width)
        .round()
        .clamp(0, widget.session.terminal.viewWidth)
        .toInt();
    final row = (((local.dy - origin.dy) / cellSize.height).round() - 1)
        .clamp(0, widget.session.terminal.buffer.lines.length - 1)
        .toInt();
    return CellOffset(column, row);
  }

  void _endHandleDrag(DragEndDetails details) {
    _dragPointerToAnchor = null;
  }

  Future<void> _copySelection() async {
    final selection = _controller.selectionFor(widget.session.terminal.buffer);
    if (selection == null) return;
    final text = widget.session.terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _controller.clearSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: LText('已复制终端文本'),
        duration: Duration(seconds: 1),
      ),
    );
  }
}

class _TerminalCopySheet extends StatefulWidget {
  const _TerminalCopySheet({required this.text});
  final String text;
  @override
  State<_TerminalCopySheet> createState() => _TerminalCopySheetState();
}

class _TerminalCopySheetState extends State<_TerminalCopySheet> {
  late final _text = TextEditingController(text: widget.text);
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
        heightFactor: .8,
        child: Column(children: [
          Row(children: [
            const SizedBox(width: 16),
            const Expanded(child: LText('选择并复制')),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _text,
              builder: (_, value, child) => TextButton(
                key: const ValueKey('copy-terminal-snapshot'),
                onPressed: () async {
                  final selection = value.selection;
                  final text = selection.isValid && !selection.isCollapsed
                      ? selection.textInside(value.text)
                      : value.text;
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) Navigator.pop(context);
                },
                child: LText(
                    value.selection.isValid && !value.selection.isCollapsed
                        ? '复制'
                        : '复制全部'),
              ),
            ),
            IconButton(
                tooltip: localized('关闭'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close)),
          ]),
          Expanded(
              child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const ValueKey('terminal-copy-snapshot'),
              controller: _text,
              readOnly: true,
              showCursor: false,
              expands: true,
              maxLines: null,
              minLines: null,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(border: InputBorder.none),
            ),
          )),
        ]),
      );
}

class _TerminalSelectionHandle extends StatelessWidget {
  const _TerminalSelectionHandle({
    super.key,
    required this.anchor,
    required this.color,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  static const hitSize = 44.0;

  final Offset anchor;
  final Color color;
  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;

  @override
  Widget build(BuildContext context) => Positioned(
        left: anchor.dx - hitSize / 2,
        top: anchor.dy - 2,
        width: hitSize,
        height: hitSize,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: onPanStart,
          onPanUpdate: onPanUpdate,
          onPanEnd: onPanEnd,
          child: CustomPaint(
            painter: _TerminalSelectionHandlePainter(color),
          ),
        ),
      );
}

class _TerminalSelectionHandlePainter extends CustomPainter {
  const _TerminalSelectionHandlePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final centerX = size.width / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX - 2, 0, 4, 11),
        const Radius.circular(2),
      ),
      paint,
    );
    canvas.drawCircle(Offset(centerX, 16), 11, paint);
  }

  @override
  bool shouldRepaint(_TerminalSelectionHandlePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Gives its child a height that only follows the available height once that
/// has settled. While the keyboard slides in, the available height changes on
/// nearly every frame; passing each value on made the terminal reflow,
/// re-scroll and send a new size to the server many times in a row, so the
/// text jumped up and down. The child is clipped (or shows empty space at the
/// bottom) for the short time until the height settles.
class _SettledHeight extends StatefulWidget {
  const _SettledHeight({required this.child});

  final Widget child;

  @override
  State<_SettledHeight> createState() => _SettledHeightState();
}

class _SettledHeightState extends State<_SettledHeight> {
  static const _settleDelay = Duration(milliseconds: 140);

  double? _height;
  double? _pending;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _track(double available) {
    final current = _height;
    if (current == null) {
      _height = available;
      return;
    }
    if ((available - current).abs() < 0.5) {
      _timer?.cancel();
      _pending = null;
      return;
    }
    if (_pending == available) return;
    _pending = available;
    _timer?.cancel();
    _timer = Timer(_settleDelay, () {
      if (!mounted) return;
      setState(() {
        _height = _pending ?? _height;
        _pending = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight;
        if (!available.isFinite) return widget.child;
        _track(available);
        final height = _height!;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: height,
            maxHeight: height,
            child: widget.child,
          ),
        );
      },
    );
  }
}
