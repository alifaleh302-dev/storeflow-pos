import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/generated/app_localizations.dart';
import '../app_providers.dart';
import '../router.dart';
import 'nav_destinations.dart';

/// Platform-adaptive navigation shell.
///
/// The same feature pages are shown on every platform; only the navigation
/// chrome changes. A wide window gets a permanent navigation rail plus an
/// app bar, a narrow window gets a bottom navigation bar with the overflow
/// destinations behind a "More" sheet. This is a genuine layout switch, not a
/// stretched phone layout.
class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= kDesktopBreakpoint;
    final location = GoRouterState.of(context).uri.path;
    final selected = destinationForLocation(location);

    if (isDesktop) {
      return _DesktopScaffold(
        selectedRoute: selected?.route ?? Routes.dashboard,
        child: child,
      );
    }
    return _CompactScaffold(
      selectedRoute: selected?.route ?? Routes.dashboard,
      child: child,
    );
  }
}

class _DesktopScaffold extends StatelessWidget {
  const _DesktopScaffold({required this.selectedRoute, required this.child});

  final String selectedRoute;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final all = <NavDestination>[
      ...primaryDestinations,
      ...secondaryDestinations,
    ];
    final selectedIndex =
        all.indexWhere((d) => d.route == selectedRoute).clamp(0, all.length - 1);

    return Scaffold(
      body: Row(
        children: <Widget>[
          NavigationRail(
            extended: MediaQuery.sizeOf(context).width >= 1200,
            minExtendedWidth: 200,
            selectedIndex: selectedIndex,
            onDestinationSelected: (index) =>
                context.go(all[index].route),
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Icon(
                Icons.storefront,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            destinations: <NavigationRailDestination>[
              for (final destination in all)
                NavigationRailDestination(
                  icon: Tooltip(
                    message: destination.shortcut == null
                        ? destination.labelOf(l10n)
                        : '${destination.labelOf(l10n)} (${destination.shortcut})',
                    child: Icon(destination.icon),
                  ),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: Text(destination.labelOf(l10n)),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _CompactScaffold extends StatelessWidget {
  const _CompactScaffold({required this.selectedRoute, required this.child});

  final String selectedRoute;
  final Widget child;

  /// Bottom bar can hold at most five destinations before labels truncate.
  static const int _maxBottomItems = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bottom = primaryDestinations.take(_maxBottomItems).toList();
    final overflow = <NavDestination>[
      ...primaryDestinations.skip(_maxBottomItems),
      ...secondaryDestinations,
    ];
    final selectedIndex = bottom.indexWhere((d) => d.route == selectedRoute);
    final isOverflowSelected =
        selectedIndex < 0 && overflow.any((d) => d.route == selectedRoute);

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: isOverflowSelected
            ? bottom.length
            : (selectedIndex < 0 ? 0 : selectedIndex),
        onDestinationSelected: (index) {
          if (index < bottom.length) {
            context.go(bottom[index].route);
            return;
          }
          _showMoreSheet(context, l10n, overflow);
        },
        destinations: <Widget>[
          for (final destination in bottom)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.labelOf(l10n),
            ),
          NavigationDestination(
            icon: const Icon(Icons.more_horiz),
            selectedIcon: const Icon(Icons.more_horiz),
            label: l10n.navMore,
          ),
        ],
      ),
    );
  }

  Future<void> _showMoreSheet(
    BuildContext context,
    AppLocalizations l10n,
    List<NavDestination> overflow,
  ) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final destination in overflow)
              ListTile(
                leading: Icon(destination.icon),
                title: Text(destination.labelOf(l10n)),
                selected: destination.route == selectedRoute,
                onTap: () => Navigator.of(sheetContext).pop(destination.route),
              ),
          ],
        ),
      ),
    );
    if (selected != null && context.mounted) {
      context.go(selected);
    }
  }
}
