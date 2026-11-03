import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../router.dart';

/// One entry in the application navigation.
///
/// [shortcut] is the Windows/Linux key binding shown in tooltips. Shortcuts are
/// only wired on desktop platforms; touch devices rely on the destination tap.
class NavDestination {
  const NavDestination({
    required this.route,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.shortcut,
    this.desktopOnly = false,
  });

  final String route;
  final IconData icon;
  final IconData selectedIcon;
  final String Function(AppLocalizations l10n) label;
  final String? shortcut;

  /// Hidden from the compact (mobile) navigation bar to avoid crowding.
  final bool desktopOnly;

  String labelOf(AppLocalizations l10n) => label(l10n);
}

/// Primary destinations, in display order. The first five appear in the mobile
/// bottom bar; the remainder live behind "More" on compact layouts.
final List<NavDestination> primaryDestinations = <NavDestination>[
  NavDestination(
    route: Routes.dashboard,
    icon: Icons.dashboard_outlined,
    selectedIcon: Icons.dashboard,
    label: (l10n) => l10n.navDashboard,
  ),
  NavDestination(
    route: Routes.pos,
    icon: Icons.point_of_sale_outlined,
    selectedIcon: Icons.point_of_sale,
    label: (l10n) => l10n.navPos,
  ),
  NavDestination(
    route: Routes.products,
    icon: Icons.inventory_2_outlined,
    selectedIcon: Icons.inventory_2,
    label: (l10n) => l10n.navProducts,
  ),
  NavDestination(
    route: Routes.inventory,
    icon: Icons.warehouse_outlined,
    selectedIcon: Icons.warehouse,
    label: (l10n) => l10n.navInventory,
  ),
  NavDestination(
    route: Routes.reports,
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights,
    label: (l10n) => l10n.navReports,
  ),
];

/// Secondary destinations, shown in the desktop rail and the mobile "More" list.
final List<NavDestination> secondaryDestinations = <NavDestination>[
  NavDestination(
    route: Routes.purchases,
    icon: Icons.local_shipping_outlined,
    selectedIcon: Icons.local_shipping,
    label: (l10n) => l10n.navPurchases,
  ),
  NavDestination(
    route: Routes.customers,
    icon: Icons.people_outline,
    selectedIcon: Icons.people,
    label: (l10n) => l10n.navCustomers,
  ),
  NavDestination(
    route: Routes.suppliers,
    icon: Icons.storefront_outlined,
    selectedIcon: Icons.storefront,
    label: (l10n) => l10n.navSuppliers,
  ),
  NavDestination(
    route: Routes.expenses,
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    label: (l10n) => l10n.navExpenses,
  ),
  NavDestination(
    route: Routes.cashRegister,
    icon: Icons.account_balance_wallet_outlined,
    selectedIcon: Icons.account_balance_wallet,
    label: (l10n) => l10n.navCashRegister,
  ),
  NavDestination(
    route: Routes.settings,
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    label: (l10n) => l10n.navSettings,
  ),
];

/// Returns the destination whose route is the longest prefix of [location].
NavDestination? destinationForLocation(String location) {
  NavDestination? best;
  for (final destination in <NavDestination>[
    ...primaryDestinations,
    ...secondaryDestinations,
  ]) {
    final matches = destination.route == Routes.dashboard
        ? location == Routes.dashboard
        : location == destination.route ||
            location.startsWith('${destination.route}/');
    if (matches) {
      if (best == null || destination.route.length > best.route.length) {
        best = destination;
      }
    }
  }
  return best;
}
