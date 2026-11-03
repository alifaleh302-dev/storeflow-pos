import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/backup/presentation/pages/backup_page.dart';
import '../features/cash_register/presentation/pages/cash_register_page.dart';
import '../features/currencies/presentation/pages/currencies_page.dart';
import '../features/customers/presentation/pages/customers_page.dart';
import '../features/dashboard/presentation/pages/dashboard_page.dart';
import '../features/expenses/presentation/pages/expenses_page.dart';
import '../features/inventory/presentation/pages/inventory_page.dart';
import '../features/products/presentation/pages/product_detail_page.dart';
import '../features/products/presentation/pages/product_form_page.dart';
import '../features/products/presentation/pages/products_page.dart';
import '../features/purchases/presentation/pages/purchases_page.dart';
import '../features/reports/presentation/pages/reports_page.dart';
import '../features/sales/presentation/pages/pos_page.dart';
import '../features/sales/presentation/pages/sales_history_page.dart';
import '../features/settings/presentation/pages/settings_page.dart';
import '../features/suppliers/presentation/pages/suppliers_page.dart';
import 'shell/adaptive_shell.dart';

/// Route path constants, referenced from navigation code and tests.
abstract final class Routes {
  static const String dashboard = '/';
  static const String pos = '/pos';
  static const String products = '/products';
  static const String productNew = '/products/new';
  static const String inventory = '/inventory';
  static const String purchases = '/purchases';
  static const String customers = '/customers';
  static const String suppliers = '/suppliers';
  static const String expenses = '/expenses';
  static const String cashRegister = '/cash-register';
  static const String reports = '/reports';
  static const String salesHistory = '/sales';
  static const String currencies = '/currencies';
  static const String backup = '/backup';
  static const String settings = '/settings';

  /// Builds the edit route for an existing product.
  static String productEdit(int id) => '/products/$id/edit';

  /// Builds the detail route for an existing product.
  static String productDetail(int id) => '/products/$id';
}

/// Application router.
///
/// All feature routes are declared here so navigation is inspectable in one
/// place. Nested routes keep the shell (and therefore the selected navigation
/// destination) visible.
GoRouter buildRouter({String initialLocation = Routes.dashboard}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      ShellRoute(
        builder: (context, state, child) => AdaptiveShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: Routes.dashboard,
            name: 'dashboard',
            builder: (context, state) => const DashboardPage(),
          ),
          GoRoute(
            path: Routes.pos,
            name: 'pos',
            builder: (context, state) => const PosPage(),
          ),
          GoRoute(
            path: Routes.salesHistory,
            name: 'salesHistory',
            builder: (context, state) => const SalesHistoryPage(),
          ),
          GoRoute(
            path: Routes.products,
            name: 'products',
            builder: (context, state) => const ProductsPage(),
            routes: <RouteBase>[
              GoRoute(
                path: 'new',
                name: 'productNew',
                builder: (context, state) => const ProductFormPage(),
              ),
              GoRoute(
                path: ':id',
                name: 'productDetail',
                builder: (context, state) => ProductDetailPage(
                  productId: int.parse(state.pathParameters['id']!),
                ),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'edit',
                    name: 'productEdit',
                    builder: (context, state) => ProductFormPage(
                      productId: int.parse(state.pathParameters['id']!),
                    ),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: Routes.inventory,
            name: 'inventory',
            builder: (context, state) => const InventoryPage(),
          ),
          GoRoute(
            path: Routes.purchases,
            name: 'purchases',
            builder: (context, state) => const PurchasesPage(),
          ),
          GoRoute(
            path: Routes.customers,
            name: 'customers',
            builder: (context, state) => const CustomersPage(),
          ),
          GoRoute(
            path: Routes.suppliers,
            name: 'suppliers',
            builder: (context, state) => const SuppliersPage(),
          ),
          GoRoute(
            path: Routes.expenses,
            name: 'expenses',
            builder: (context, state) => const ExpensesPage(),
          ),
          GoRoute(
            path: Routes.cashRegister,
            name: 'cashRegister',
            builder: (context, state) => const CashRegisterPage(),
          ),
          GoRoute(
            path: Routes.reports,
            name: 'reports',
            builder: (context, state) => const ReportsPage(),
          ),
          GoRoute(
            path: Routes.currencies,
            name: 'currencies',
            builder: (context, state) => const CurrenciesPage(),
          ),
          GoRoute(
            path: Routes.backup,
            name: 'backup',
            builder: (context, state) => const BackupPage(),
          ),
          GoRoute(
            path: Routes.settings,
            name: 'settings',
            builder: (context, state) => const SettingsPage(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      appBar: AppBar(title: const Text('Not found')),
      body: Center(child: Text(state.error?.toString() ?? 'Page not found')),
    ),
  );
}
