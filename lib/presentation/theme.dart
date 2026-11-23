import 'package:flutter/material.dart';

/// One colour scheme of a light/dark theme pair, including its terminal
/// palette.
class NetcattyThemePreset {
  const NetcattyThemePreset({
    required this.id,
    required this.name,
    required this.brightness,
    required this.background,
    required this.foreground,
    required this.card,
    required this.primary,
    required this.border,
    required this.error,
    required this.ansi,
  });

  final String id;
  final String name;
  final Brightness brightness;
  final Color background;
  final Color foreground;
  final Color card;
  final Color primary;
  final Color border;
  final Color error;

  /// The 16 ANSI colours: black, red, green, yellow, blue, magenta, cyan,
  /// white, then the bright variants in the same order.
  final List<Color> ansi;
}

/// Terminal ANSI palette of the active theme, read by the terminal view.
class TerminalPalette extends ThemeExtension<TerminalPalette> {
  const TerminalPalette(this.ansi);

  final List<Color> ansi;

  @override
  TerminalPalette copyWith({List<Color>? ansi}) =>
      TerminalPalette(ansi ?? this.ansi);

  @override
  TerminalPalette lerp(TerminalPalette? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

class NetcattyTheme {
  static const defaultId = 'claude';

  /// Interface font (DM Sans; CJK falls back to the system font).
  static const uiFont = 'DMSans';

  /// Heading font (Lora), used for the app title and large headings.
  static const displayFont = 'Lora';

  static List<NetcattyThemePreset> presets(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  static NetcattyThemePreset resolve(Brightness brightness, String id) {
    final available = presets(brightness);
    return available.firstWhere(
      (preset) => preset.id == id,
      // Themes removed in 1.9.2 (the old 62-theme catalogue) fall back here.
      orElse: () => available.first,
    );
  }

  static final _cache = <(Brightness, String), ThemeData>{};

  /// Themes are cached: building one runs ColorScheme.fromSeed (a tonal
  /// palette computation) and used to happen twice on every settings change.
  static ThemeData build(Brightness brightness, String id) =>
      _cache.putIfAbsent((brightness, id), () => _build(brightness, id));

  static ThemeData _build(Brightness brightness, String id) {
    final preset = resolve(brightness, id);
    final dark = brightness == Brightness.dark;
    final muted = Color.lerp(preset.foreground, preset.background, 0.45)!;
    final fill = preset.foreground.withValues(alpha: dark ? 0.07 : 0.045);
    final seed = ColorScheme.fromSeed(
      seedColor: preset.primary,
      brightness: brightness,
    );
    final scheme = seed.copyWith(
      primary: preset.primary,
      onPrimary: _contrast(preset.primary),
      secondary: preset.primary,
      onSecondary: _contrast(preset.primary),
      surface: preset.card,
      onSurface: preset.foreground,
      onSurfaceVariant: muted,
      surfaceContainerLowest: preset.background,
      surfaceContainerLow: preset.card,
      surfaceContainer: preset.card,
      surfaceContainerHigh: Color.alphaBlend(fill, preset.card),
      surfaceContainerHighest: Color.alphaBlend(fill, preset.card),
      outline: preset.border,
      outlineVariant: preset.border.withValues(alpha: 0.7),
      error: preset.error,
      onError: _contrast(preset.error),
    );
    // Claude-style primary action: an ink-coloured pill (near black in
    // light mode, near white in dark mode).
    final ink = preset.foreground;
    final onInk = preset.background;
    final base = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamily: uiFont,
      colorScheme: scheme,
    );
    final text = base.textTheme.apply(
      bodyColor: preset.foreground,
      displayColor: preset.foreground,
    );
    return base.copyWith(
      scaffoldBackgroundColor: preset.background,
      canvasColor: preset.background,
      extensions: [TerminalPalette(preset.ansi)],
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(
          fontFamily: displayFont,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w500),
        bodySmall: text.bodySmall?.copyWith(color: muted),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: preset.background,
        foregroundColor: preset.foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: uiFont,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: preset.foreground,
        ),
      ),
      // Borderless rounded panels, like iOS inset-grouped lists.
      cardTheme: CardThemeData(
        color: preset.card,
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      dividerTheme: DividerThemeData(
        color: preset.border.withValues(alpha: dark ? 0.8 : 1),
        thickness: 0.6,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: Color.lerp(preset.foreground, preset.background, 0.25),
        titleTextStyle: TextStyle(
          fontFamily: uiFont,
          fontSize: 16,
          color: preset.foreground,
        ),
        subtitleTextStyle: TextStyle(
          fontFamily: uiFont,
          fontSize: 13,
          color: muted,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: preset.primary.withValues(alpha: 0.7)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: onInk,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontFamily: uiFont,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: preset.foreground,
          shape: const StadiumBorder(),
          side: BorderSide(color: preset.border),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: preset.foreground),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : (dark ? const Color(0xff9a9a96) : Colors.white),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? preset.primary
              : preset.foreground.withValues(alpha: dark ? 0.16 : 0.12),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          side: BorderSide(color: preset.border),
          selectedBackgroundColor: preset.foreground.withValues(alpha: 0.08),
          selectedForegroundColor: preset.foreground,
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: preset.border),
        backgroundColor: preset.card,
        selectedColor: preset.foreground.withValues(alpha: 0.1),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: preset.card,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.5 : 0.16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: preset.border.withValues(alpha: 0.5)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: preset.background,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: preset.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      // Floating so it sits above the tab bar instead of under it.
      snackBarTheme: SnackBarThemeData(
        backgroundColor:
            dark ? const Color(0xff333331) : const Color(0xff242423),
        contentTextStyle: const TextStyle(
          fontFamily: uiFont,
          color: Colors.white,
        ),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  static Color _contrast(Color color) =>
      color.computeLuminance() > 0.46 ? Colors.black : Colors.white;
}

List<Color> _palette(List<int> values) =>
    List<Color>.unmodifiable(values.map(Color.new));

NetcattyThemePreset _theme(
  String id,
  String name,
  Brightness brightness, {
  required int background,
  required int card,
  required int foreground,
  required int primary,
  required int border,
  required int error,
  required List<int> ansi,
}) =>
    NetcattyThemePreset(
      id: id,
      name: name,
      brightness: brightness,
      background: Color(background),
      card: Color(card),
      foreground: Color(foreground),
      primary: Color(primary),
      border: Color(border),
      error: Color(error),
      ansi: _palette(ansi),
    );

const _l = Brightness.light;
const _d = Brightness.dark;

/// A short list of light/dark pairs that read well for code. Each id exists
/// in both lists so one choice covers light and dark mode.
final _light = <NetcattyThemePreset>[
  _theme('claude', 'Claude', _l,
      background: 0xfff9f9f7,
      card: 0xffffffff,
      foreground: 0xff141413,
      primary: 0xffc6613f,
      border: 0xffe6e5e0,
      error: 0xffc33b3b,
      ansi: [
        0xff141413, 0xffc7372f, 0xff3d8a2e, 0xff9a6b00, //
        0xff2e62c9, 0xffa23ca8, 0xff1a8a8a, 0xff8a8983, //
        0xff5c5b56, 0xffe0493f, 0xff4fa33c, 0xffb7860b, //
        0xff4a7fe0, 0xffba55c0, 0xff23a3a3, 0xffb5b4ad,
      ]),
  _theme('github', 'GitHub', _l,
      background: 0xfff6f8fa,
      card: 0xffffffff,
      foreground: 0xff1f2328,
      primary: 0xff0969da,
      border: 0xffd0d7de,
      error: 0xffcf222e,
      ansi: [
        0xff24292f, 0xffcf222e, 0xff116329, 0xff4d2d00, //
        0xff0969da, 0xff8250df, 0xff1b7c83, 0xff6e7781, //
        0xff57606a, 0xffa40e26, 0xff1a7f37, 0xff633c01, //
        0xff218bff, 0xffa475f9, 0xff3192aa, 0xff8c959f,
      ]),
  _theme('one', 'One', _l,
      background: 0xffeaeaeb,
      card: 0xfffafafa,
      foreground: 0xff383a42,
      primary: 0xff4078f2,
      border: 0xffdbdbdc,
      error: 0xffe45649,
      ansi: [
        0xff383a42, 0xffe45649, 0xff50a14f, 0xffc18401, //
        0xff4078f2, 0xffa626a4, 0xff0184bc, 0xffa0a1a7, //
        0xff4f525e, 0xffca1243, 0xff3e953a, 0xff986801, //
        0xff2f5af3, 0xff9a1a99, 0xff0997b3, 0xff8e8f96,
      ]),
  _theme('tokyo-night', 'Tokyo Night', _l,
      background: 0xffd0d5e3,
      card: 0xffe1e2e7,
      foreground: 0xff3760bf,
      primary: 0xff2e7de9,
      border: 0xffc4c8da,
      error: 0xfff52a65,
      ansi: [
        0xff343b58, 0xfff52a65, 0xff587539, 0xff8c6c3e, //
        0xff2e7de9, 0xff9854f1, 0xff007197, 0xff6172b0, //
        0xff4c505e, 0xfff52a65, 0xff587539, 0xff8c6c3e, //
        0xff2e7de9, 0xff9854f1, 0xff007197, 0xffa1a6c5,
      ]),
  _theme('catppuccin', 'Catppuccin', _l,
      background: 0xffe6e9ef,
      card: 0xffeff1f5,
      foreground: 0xff4c4f69,
      primary: 0xff8839ef,
      border: 0xffccd0da,
      error: 0xffd20f39,
      ansi: [
        0xff5c5f77, 0xffd20f39, 0xff40a02b, 0xffdf8e1d, //
        0xff1e66f5, 0xffea76cb, 0xff179299, 0xffacb0be, //
        0xff6c6f85, 0xffd20f39, 0xff40a02b, 0xffdf8e1d, //
        0xff1e66f5, 0xffea76cb, 0xff179299, 0xffbcc0cc,
      ]),
  _theme('dracula', 'Dracula', _l,
      background: 0xfff5f1df,
      card: 0xfffffbeb,
      foreground: 0xff1f1f1f,
      primary: 0xff644ac9,
      border: 0xffdedccf,
      error: 0xffcb3a2a,
      ansi: [
        0xff1f1f1f, 0xffcb3a2a, 0xff14710a, 0xff846e15, //
        0xff644ac9, 0xffa3144d, 0xff036a96, 0xff6c664b, //
        0xff635d97, 0xffd74c3d, 0xff198d0c, 0xff9e841a, //
        0xff7862d0, 0xffbf185a, 0xff047fb4, 0xff8a8463,
      ]),
  _theme('nord', 'Nord', _l,
      background: 0xffe5e9f0,
      card: 0xffeceff4,
      foreground: 0xff2e3440,
      primary: 0xff5e81ac,
      border: 0xffd8dee9,
      error: 0xffbf616a,
      ansi: [
        0xff2e3440, 0xffb04a55, 0xff5e7d45, 0xff9a7426, //
        0xff4c6e94, 0xff8c6585, 0xff3b7e8c, 0xff7b8394, //
        0xff4c566a, 0xffbf616a, 0xff6e8f4f, 0xffaf8a3c, //
        0xff5e81ac, 0xffa07397, 0xff4c8e9c, 0xff9aa2b4,
      ]),
  _theme('gruvbox', 'Gruvbox', _l,
      background: 0xfff2e5bc,
      card: 0xfffbf1c7,
      foreground: 0xff3c3836,
      primary: 0xffaf3a03,
      border: 0xffd5c4a1,
      error: 0xff9d0006,
      ansi: [
        0xff3c3836, 0xffcc241d, 0xff98971a, 0xffd79921, //
        0xff458588, 0xffb16286, 0xff689d6a, 0xff7c6f64, //
        0xff928374, 0xff9d0006, 0xff79740e, 0xffb57614, //
        0xff076678, 0xff8f3f71, 0xff427b58, 0xff665c54,
      ]),
];

final _dark = <NetcattyThemePreset>[
  _theme('claude', 'Claude', _d,
      background: 0xff151515,
      card: 0xff20201f,
      foreground: 0xfff8f8f6,
      primary: 0xffd97757,
      border: 0xff2e2e2c,
      error: 0xffe5534b,
      ansi: [
        0xff4a4945, 0xffe06c64, 0xff8fbf7a, 0xffe5c07b, //
        0xff7aa2e3, 0xffc792c9, 0xff6fc0c0, 0xffd8d6cf, //
        0xff6e6c66, 0xfff08a80, 0xffa8d48f, 0xfff0d290, //
        0xff98b8f0, 0xffd9a8db, 0xff8dd5d5, 0xfff8f8f6,
      ]),
  _theme('github', 'GitHub', _d,
      background: 0xff010409,
      card: 0xff0d1117,
      foreground: 0xffe6edf3,
      primary: 0xff4493f8,
      border: 0xff30363d,
      error: 0xfff85149,
      ansi: [
        0xff484f58, 0xffff7b72, 0xff3fb950, 0xffd29922, //
        0xff58a6ff, 0xffbc8cff, 0xff39c5cf, 0xffb1bac4, //
        0xff6e7681, 0xffffa198, 0xff56d364, 0xffe3b341, //
        0xff79c0ff, 0xffd2a8ff, 0xff56d4dd, 0xfff0f6fc,
      ]),
  _theme('one', 'One', _d,
      background: 0xff21252b,
      card: 0xff282c34,
      foreground: 0xffabb2bf,
      primary: 0xff61afef,
      border: 0xff3e4451,
      error: 0xffe06c75,
      ansi: [
        0xff5c6370, 0xffe06c75, 0xff98c379, 0xffe5c07b, //
        0xff61afef, 0xffc678dd, 0xff56b6c2, 0xffabb2bf, //
        0xff7f848e, 0xfff08c93, 0xffafd490, 0xfff0d197, //
        0xff82c1f3, 0xffd49be6, 0xff7acad3, 0xffe6e6e6,
      ]),
  _theme('tokyo-night', 'Tokyo Night', _d,
      background: 0xff16161e,
      card: 0xff1a1b26,
      foreground: 0xffc0caf5,
      primary: 0xff7aa2f7,
      border: 0xff292e42,
      error: 0xfff7768e,
      ansi: [
        0xff32344a, 0xfff7768e, 0xff9ece6a, 0xffe0af68, //
        0xff7aa2f7, 0xffbb9af7, 0xff7dcfff, 0xffa9b1d6, //
        0xff414868, 0xfff7768e, 0xff9ece6a, 0xffe0af68, //
        0xff7aa2f7, 0xffbb9af7, 0xff7dcfff, 0xffc0caf5,
      ]),
  _theme('catppuccin', 'Catppuccin', _d,
      background: 0xff181825,
      card: 0xff1e1e2e,
      foreground: 0xffcdd6f4,
      primary: 0xffcba6f7,
      border: 0xff313244,
      error: 0xfff38ba8,
      ansi: [
        0xff45475a, 0xfff38ba8, 0xffa6e3a1, 0xfff9e2af, //
        0xff89b4fa, 0xfff5c2e7, 0xff94e2d5, 0xffbac2de, //
        0xff585b70, 0xfff38ba8, 0xffa6e3a1, 0xfff9e2af, //
        0xff89b4fa, 0xfff5c2e7, 0xff94e2d5, 0xffa6adc8,
      ]),
  _theme('dracula', 'Dracula', _d,
      background: 0xff21222c,
      card: 0xff282a36,
      foreground: 0xfff8f8f2,
      primary: 0xffbd93f9,
      border: 0xff44475a,
      error: 0xffff5555,
      ansi: [
        0xff44475a, 0xffff5555, 0xff50fa7b, 0xfff1fa8c, //
        0xffbd93f9, 0xffff79c6, 0xff8be9fd, 0xfff8f8f2, //
        0xff6272a4, 0xffff6e6e, 0xff69ff94, 0xffffffa5, //
        0xffd6acff, 0xffff92df, 0xffa4ffff, 0xffffffff,
      ]),
  _theme('nord', 'Nord', _d,
      background: 0xff2e3440,
      card: 0xff3b4252,
      foreground: 0xffeceff4,
      primary: 0xff88c0d0,
      border: 0xff4c566a,
      error: 0xffbf616a,
      ansi: [
        0xff4c566a, 0xffbf616a, 0xffa3be8c, 0xffebcb8b, //
        0xff81a1c1, 0xffb48ead, 0xff88c0d0, 0xffe5e9f0, //
        0xff616e88, 0xffbf616a, 0xffa3be8c, 0xffebcb8b, //
        0xff81a1c1, 0xffb48ead, 0xff8fbcbb, 0xffeceff4,
      ]),
  _theme('gruvbox', 'Gruvbox', _d,
      background: 0xff1d2021,
      card: 0xff282828,
      foreground: 0xffebdbb2,
      primary: 0xfffe8019,
      border: 0xff3c3836,
      error: 0xfffb4934,
      ansi: [
        0xff3c3836, 0xffcc241d, 0xff98971a, 0xffd79921, //
        0xff458588, 0xffb16286, 0xff689d6a, 0xffa89984, //
        0xff928374, 0xfffb4934, 0xffb8bb26, 0xfffabd2f, //
        0xff83a598, 0xffd3869b, 0xff8ec07c, 0xffebdbb2,
      ]),
];
