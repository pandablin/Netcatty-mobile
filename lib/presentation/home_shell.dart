import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/home_navigation.dart';
import '../application/settings_controller.dart';
import '../infrastructure/ssh/terminal_picture_in_picture_service.dart';
import 'localization/localized_widgets.dart';
import 'screens/settings_screen.dart';
import 'screens/sftp_screen.dart';
import 'screens/snippets_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/vault_screen.dart';
import 'widgets/custom_background.dart';
import 'widgets/glass.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _pages = [
    VaultScreen(),
    TerminalScreen(),
    SftpScreen(),
    SnippetsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(homeTabProvider);
    final terminalFullscreen = ref.watch(terminalFullscreenProvider);
    final terminalPictureInPicture =
        ref.watch(terminalPictureInPictureProvider);
    final settings = ref.watch(settingsControllerProvider);
    final customBackground = customBackgroundAppliesToTab(settings, index);
    final globalBackground = hasGlobalCustomBackground(settings);
    final hideNavigation = shouldHideHomeNavigation(
      index,
      terminalFullscreen || terminalPictureInPicture,
    );
    return PopScope(
      canPop: !hideNavigation,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && hideNavigation) {
          if (terminalPictureInPicture) {
            ref.read(terminalPictureInPictureProvider.notifier).state = false;
            unawaited(TerminalPictureInPictureService.stop());
          } else {
            ref.read(terminalFullscreenProvider.notifier).state = false;
          }
        }
      },
      child: Scaffold(
        // Pages scroll under the floating glass tab bar. The terminal keeps
        // its own layout (it stops above the bar) unless a background image
        // spans every tab.
        extendBody: globalBackground || index != 1,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Keep this slot even without a background: inserting it only on
            // some tabs shifted the page stack to another child position, so
            // Flutter rebuilt every page and the terminal lost its state.
            if (customBackground)
              CustomBackgroundImage(settings: settings)
            else
              const SizedBox.shrink(),
            Theme(
              data: customBackground
                  ? Theme.of(context).copyWith(
                      scaffoldBackgroundColor: Colors.transparent,
                      appBarTheme: Theme.of(context).appBarTheme.copyWith(
                            backgroundColor: Colors.transparent,
                          ),
                    )
                  : Theme.of(context),
              child: IndexedStack(index: index, children: _pages),
            ),
          ],
        ),
        bottomNavigationBar: hideNavigation
            ? null
            : _navigationBar(ref, index),
      ),
    );
  }

  Widget _navigationBar(WidgetRef ref, int selectedIndex) =>
      GlassTabBar(
        key: const ValueKey('home-navigation-bar'),
        selectedIndex: selectedIndex,
        onSelected: (value) => ref.read(homeTabProvider.notifier).state = value,
        items: [
          GlassTabItem(
            icon: Icons.dns_outlined,
            selectedIcon: Icons.dns,
            label: localized('保险库'),
          ),
          GlassTabItem(
            icon: Icons.terminal_outlined,
            selectedIcon: Icons.terminal,
            label: localized('终端'),
          ),
          GlassTabItem(
            icon: Icons.folder_outlined,
            selectedIcon: Icons.folder,
            label: localized('文件'),
          ),
          GlassTabItem(
            icon: Icons.code_outlined,
            selectedIcon: Icons.code,
            label: localized('片段'),
          ),
          GlassTabItem(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: localized('设置'),
          ),
        ],
      );
}

bool shouldHideHomeNavigation(int tabIndex, bool terminalFullscreen) =>
    tabIndex == 1 && terminalFullscreen;
