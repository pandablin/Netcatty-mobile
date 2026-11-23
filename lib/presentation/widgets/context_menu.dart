import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../localization/localized_widgets.dart';

class ContextMenuAction<T> {
  const ContextMenuAction({
    required this.value,
    required this.label,
    required this.icon,
    this.destructive = false,
  });

  final T value;
  final String label;
  final IconData icon;

  /// Shown in red, after a separator (e.g. delete).
  final bool destructive;
}

/// The global rectangle of the widget that owns [context], used to anchor a
/// context menu to the long-pressed item.
Rect globalRectOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// iOS-style context menu: the screen blurs, [preview] lifts at [anchor],
/// and the actions appear below it. The group moves up when needed, and the
/// actions scroll when the available height cannot fit the whole menu.
Future<T?> showContextMenu<T>({
  required BuildContext context,
  required Rect anchor,
  required Widget preview,
  required List<ContextMenuAction<T>> actions,
}) =>
    Navigator.of(context, rootNavigator: true).push<T>(
      _ContextMenuRoute<T>(
        anchor: anchor,
        preview: preview,
        actions: actions,
        barrierLabel:
            MaterialLocalizations.of(context).modalBarrierDismissLabel,
      ),
    );

class _ContextMenuRoute<T> extends PopupRoute<T> {
  _ContextMenuRoute({
    required this.anchor,
    required this.preview,
    required this.actions,
    required this.barrierLabel,
  });

  final Rect anchor;
  final Widget preview;
  final List<ContextMenuAction<T>> actions;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 170);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    final pop = CurvedAnimation(
      parent: animation,
      curve: const Cubic(0.34, 1.32, 0.64, 1),
      reverseCurve: Curves.easeIn,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        // The blur is static while the menu is open, so it is only computed
        // during the short fade.
        FadeTransition(
          opacity: fade,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.pop(context),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: ColoredBox(
                color: Colors.black.withValues(alpha: dark ? 0.35 : 0.14),
              ),
            ),
          ),
        ),
        CustomMultiChildLayout(
          delegate: _ContextMenuLayout(
            anchor: anchor,
            padding: MediaQuery.paddingOf(context),
          ),
          children: [
            LayoutId(
              id: _Slot.preview,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.97, end: 1).animate(pop),
                child: FadeTransition(
                  opacity: fade,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: dark ? 0.45 : 0.16),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      // Keep oversized previews from overflowing their height
                      // budget. The preview is decorative, not interactive.
                      child: SingleChildScrollView(
                        primary: false,
                        physics: const NeverScrollableScrollPhysics(),
                        child: preview,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            LayoutId(
              id: _Slot.menu,
              child: FadeTransition(
                opacity: fade,
                child: ScaleTransition(
                  alignment: Alignment.topLeft,
                  scale: Tween<double>(begin: 0.85, end: 1).animate(pop),
                  child: _ContextMenuPanel<T>(actions: actions),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

enum _Slot { preview, menu }

class _ContextMenuLayout extends MultiChildLayoutDelegate {
  _ContextMenuLayout({required this.anchor, required this.padding});

  final Rect anchor;
  final EdgeInsets padding;

  static const _margin = 16.0;
  static const _gap = 10.0;

  @override
  void performLayout(Size size) {
    final available = math.max(0.0, size.width - _margin * 2);
    final top = padding.top + 8;
    final bottom = math.max(top, size.height - padding.bottom - 8);
    final availableHeight = bottom - top;
    final gap = math.min(_gap, availableHeight);
    // Reserve at least two action rows where possible. A large preview must
    // not consume the entire viewport and make the menu impossible to use.
    final menuReserve = math.min(96.0, availableHeight - gap);
    // Narrow grid cards get a wider preview so the details fit.
    final previewWidth = math.min(math.max(anchor.width, 300.0), available);
    final previewSize = layoutChild(
      _Slot.preview,
      BoxConstraints(
        minWidth: previewWidth,
        maxWidth: previewWidth,
        maxHeight: math.max(0.0, availableHeight - gap - menuReserve),
      ),
    );
    final menuWidth = math.min(250.0, available);
    final menuSize = layoutChild(
      _Slot.menu,
      BoxConstraints(
        minWidth: menuWidth,
        maxWidth: menuWidth,
        maxHeight: math.max(0.0, availableHeight - previewSize.height - gap),
      ),
    );
    final total = previewSize.height + gap + menuSize.height;
    final previewLeft = anchor.left
        .clamp(_margin, math.max(_margin, size.width - _margin - previewWidth))
        .toDouble();
    var previewTop = anchor.top;
    if (previewTop + total > bottom) previewTop = bottom - total;
    if (previewTop < top) previewTop = top;
    positionChild(_Slot.preview, Offset(previewLeft, previewTop));
    final menuLeft = previewLeft
        .clamp(
            _margin, math.max(_margin, size.width - _margin - menuSize.width))
        .toDouble();
    positionChild(
      _Slot.menu,
      Offset(menuLeft, previewTop + previewSize.height + gap),
    );
  }

  @override
  bool shouldRelayout(_ContextMenuLayout oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.padding != padding;
}

class _ContextMenuPanel<T> extends StatelessWidget {
  const _ContextMenuPanel({required this.actions});

  final List<ContextMenuAction<T>> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final rows = <Widget>[];
    for (var index = 0; index < actions.length; index++) {
      final action = actions[index];
      if (index > 0) {
        // iOS separates destructive actions with a thicker gap.
        rows.add(
          action.destructive
              ? Container(
                  height: 7,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: dark ? 0.12 : 0.06),
                )
              : const Divider(height: 1, indent: 48),
        );
      }
      final color = action.destructive
          ? theme.colorScheme.error
          : theme.colorScheme.onSurface;
      rows.add(
        InkWell(
          key: ValueKey('context-menu-${action.value}'),
          onTap: () => Navigator.pop(context, action.value),
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(action.icon, size: 20, color: color),
                const SizedBox(width: 14),
                Expanded(
                  child: LText(
                    action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Material(
      color: theme.colorScheme.surface,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.5 : 0.2),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        primary: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      ),
    );
  }
}
