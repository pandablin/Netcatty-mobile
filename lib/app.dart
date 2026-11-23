import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/auto_sync_controller.dart';
import 'application/home_navigation.dart';
import 'application/live_activity_controller.dart';
import 'application/settings_controller.dart';
import 'application/session_controller.dart';
import 'infrastructure/ssh/connection_platform_service.dart';
import 'presentation/home_shell.dart';
import 'presentation/localization/localized_widgets.dart';
import 'presentation/theme.dart';

class NetcattyApp extends ConsumerStatefulWidget {
  const NetcattyApp({super.key});

  @override
  ConsumerState<NetcattyApp> createState() => _NetcattyAppState();
}

class _NetcattyAppState extends ConsumerState<NetcattyApp>
    with WidgetsBindingObserver {
  late final ProviderSubscription<bool> _autoSyncSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoSyncSubscription = ref.listenManual<bool>(
      settingsControllerProvider.select((settings) => settings.autoSyncEnabled),
      (_, enabled) =>
          ref.read(autoSyncControllerProvider.notifier).setEnabled(enabled),
      fireImmediately: true,
    );
    // Starts mirroring terminal sessions into the iOS Dynamic Island.
    ref.read(liveActivityControllerProvider);
  }

  @override
  void dispose() {
    _autoSyncSubscription.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Tapping the Dynamic Island / Lock Screen activity opens
  /// netcatty:///session/<id>: show that terminal. This observer is
  /// registered before MaterialApp's, and the app has no named routes, so
  /// every incoming link (also ssh:// ones) is consumed here and never
  /// reaches the Navigator.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    final id = sessionIdFromDeepLink(routeInformation.uri);
    if (id == null) return true;
    final sessions = ref.read(sessionControllerProvider);
    final index = sessions.sessions.indexWhere((session) => session.id == id);
    if (index >= 0) {
      ref.read(sessionControllerProvider.notifier).activate(index);
    }
    ref.read(homeTabProvider.notifier).state = 1;
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ConnectionPlatformService.endBackgroundGrace();
      ref.read(sessionControllerProvider.notifier).setBackgrounded(false);
      ref.read(autoSyncControllerProvider.notifier).onAppResumed();
      // A Live Activity can only be started in the foreground; retry here.
      ref.read(liveActivityControllerProvider).schedule();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      ConnectionPlatformService.beginBackgroundGrace();
      if (state != AppLifecycleState.inactive) {
        ref.read(sessionControllerProvider.notifier).setBackgrounded(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      sessionControllerProvider.select(
        // Start while the user-initiated connection is still in the foreground;
        // Android 12+ can reject a service first started after the app is hidden.
        // A disconnected tab also keeps it alive so recovery retains CPU time.
        (value) =>
            value.sessions.isNotEmpty ||
            value.pendingConnections.any(
              (connection) =>
                  connection.phase == PendingConnectionPhase.connecting,
            ),
      ),
      (previous, next) => ConnectionPlatformService.setActive(next),
    );
    // Only these fields affect MaterialApp; watching all settings rebuilt it
    // (and both themes) for every toggle.
    final settings = ref.watch(
      settingsControllerProvider.select(
        (value) => (
          themeMode: value.themeMode,
          uiThemeId: value.uiThemeId,
          language: value.language,
        ),
      ),
    );
    NetcattyLocalizations.use(settings.language);
    final mode = switch (settings.themeMode) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    return MaterialApp(
      title: 'Netcatty',
      debugShowCheckedModeBanner: false,
      theme: NetcattyTheme.build(Brightness.light, settings.uiThemeId),
      darkTheme: NetcattyTheme.build(Brightness.dark, settings.uiThemeId),
      themeMode: mode,
      // Switch themes instantly: the default 200 ms cross-fade rebuilt every
      // page (terminals included) on each animation frame.
      themeAnimationDuration: Duration.zero,
      locale: settings.language == 'en'
          ? const Locale('en')
          : const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeShell(),
      // A cold start from a link sets the engine's initial route to the
      // link path; always start on the home shell instead.
      onGenerateInitialRoutes: (_) => [
        MaterialPageRoute<void>(builder: (_) => const HomeShell()),
      ],
    );
  }
}
