import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Tint, rim and shadow shared by the "liquid glass" surfaces.
class GlassStyle {
  const GlassStyle._(this.tint, this.rim, this.highlight, this.shadow);

  factory GlassStyle.of(BuildContext context, {double strength = 1}) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final surface = theme.colorScheme.surface;
    return GlassStyle._(
      surface.withValues(alpha: (dark ? 0.62 : 0.68) * strength),
      Colors.white.withValues(alpha: dark ? 0.14 : 0.75),
      Colors.white.withValues(alpha: dark ? 0.06 : 0.35),
      Colors.black.withValues(alpha: dark ? 0.38 : 0.10),
    );
  }

  final Color tint;
  final Color rim;
  final Color highlight;
  final Color shadow;
}

/// A translucent, blurred panel with a light rim and a soft drop shadow.
///
/// [blur] is the expensive part (a backdrop filter); leave it off for small
/// controls that sit on a plain background, where it would look the same.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.blur = true,
    this.padding = EdgeInsets.zero,
    this.shadow = true,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final bool blur;
  final EdgeInsetsGeometry padding;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final style = GlassStyle.of(context, strength: blur ? 1 : 1.25);
    Widget body = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(style.highlight, style.tint),
            style.tint,
          ],
        ),
        border: Border.all(color: style.rim, width: 0.8),
      ),
      child: Padding(padding: padding, child: child),
    );
    if (blur) {
      body = BackdropFilter(
        // Blur plus a saturation boost: colours behind the glass stay vivid
        // instead of turning grey.
        filter: ImageFilter.compose(
          outer: const ColorFilter.matrix(_saturate),
          inner: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        ),
        child: body,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: style.shadow,
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
              ]
            : null,
      ),
      child: ClipRRect(borderRadius: borderRadius, child: body),
    );
  }
}

// Saturation 1.6 colour matrix.
const _saturate = <double>[
  1.4748, -0.4272, -0.0476, 0, 0, //
  -0.1252, 1.1728, -0.0476, 0, 0, //
  -0.1252, -0.4272, 1.5524, 0, 0, //
  0, 0, 0, 1, 0,
];

/// Round glass button for top bars.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.size = 40,
  });

  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final button = PressScale(
      child: GlassSurface(
        blur: false,
        borderRadius: BorderRadius.circular(size / 2),
        child: SizedBox.square(
          dimension: size,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: IconTheme.merge(
                data: const IconThemeData(size: 21),
                child: Center(child: icon),
              ),
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Shrinks its child slightly while pressed, like iOS controls. It only
/// listens to pointers, so taps and long presses still reach the child.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child, this.scale = 0.96});

  final Widget child;
  final double scale;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => _set(true),
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: AnimatedScale(
          scale: _pressed ? widget.scale : 1,
          duration: Duration(milliseconds: _pressed ? 90 : 220),
          curve: _pressed ? Curves.easeOut : Curves.easeOutBack,
          child: widget.child,
        ),
      );
}

class GlassTabItem {
  const GlassTabItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Floating capsule tab bar with a glass pill that glides to the selected
/// tab (iOS 26 "Liquid Glass" style).
class GlassTabBar extends StatelessWidget {
  const GlassTabBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  static const barHeight = 62.0;

  final List<GlassTabItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Bottom gap: sits just above the home indicator, like system tab bars.
  static double bottomGap(BuildContext context) {
    final safe = MediaQuery.paddingOf(context).bottom;
    return safe > 0 ? (safe - 12).clamp(8.0, 40.0) : 10.0;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomGap(context)),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(barHeight / 2),
        child: SizedBox(
          height: barHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              const inset = 4.0;
              final slot = (constraints.maxWidth - inset * 2) / items.length;
              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 420),
                    curve: const Cubic(0.34, 1.32, 0.64, 1),
                    left: inset + slot * selectedIndex,
                    top: inset,
                    bottom: inset,
                    width: slot,
                    child: DecoratedBox(
                      key: const ValueKey('glass-tab-indicator'),
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(barHeight / 2 - inset),
                        color: scheme.onSurface
                            .withValues(alpha: dark ? 0.12 : 0.07),
                        border: Border.all(
                          color: Colors.white
                              .withValues(alpha: dark ? 0.10 : 0.6),
                          width: 0.8,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: inset),
                    child: Row(
                      children: [
                        for (var index = 0; index < items.length; index++)
                          Expanded(
                            child: _GlassTab(
                              item: items[index],
                              selected: index == selectedIndex,
                              onTap: () {
                                if (index != selectedIndex) {
                                  HapticFeedback.selectionClick();
                                }
                                onSelected(index);
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _GlassTab extends StatelessWidget {
  const _GlassTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final GlassTabItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context)
        .colorScheme
        .onSurface
        .withValues(alpha: selected ? 1 : 0.62);
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: PressScale(
        scale: 0.9,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Icon(
                  selected ? item.selectedIcon : item.icon,
                  key: ValueKey(selected),
                  size: 24,
                  color: color,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.2,
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
