import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/app/app.dart';
import 'package:storeflow_pos/app/app_providers.dart';
import 'package:storeflow_pos/app/router.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

/// Boots the real application against an in-memory database and visits every
/// route in the router, at both a phone and a desktop width.
///
/// The point is not to assert what each screen renders — most modules are still
/// placeholders — but to prove that navigation itself does not throw: every
/// page builds, every provider it watches resolves, and the shell lays out at
/// both breakpoints.
Future<void> _pumpAt(
  WidgetTester tester,
  AppDatabase db, {
  required String location,
  required Size size,
  Locale locale = const Locale('ar'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        localeProvider.overrideWith(() => _FixedLocale(locale)),
      ],
      child: StoreFlowApp(initialLocation: location),
    ),
  );
  await tester.pumpAndSettle();
}

class _FixedLocale extends LocaleController {
  _FixedLocale(this._locale);

  final Locale _locale;

  @override
  Future<Locale> build() async => _locale;
}

/// Every path the router knows about, with no parameters.
const List<String> _staticRoutes = <String>[
  Routes.dashboard,
  Routes.pos,
  Routes.products,
  Routes.productNew,
  Routes.inventory,
  Routes.purchases,
  Routes.customers,
  Routes.suppliers,
  Routes.expenses,
  Routes.cashRegister,
  Routes.reports,
  Routes.salesHistory,
  Routes.currencies,
  Routes.backup,
  Routes.settings,
];

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await db.close();
  });

  const Size phone = Size(400, 800);
  const Size desktop = Size(1600, 1000);

  for (final locale in const <Locale>[Locale('ar'), Locale('en')]) {
    for (final entry in const <String, Size>{
      'phone': phone,
      'desktop': desktop,
    }.entries) {
      testWidgets(
        'every route builds on ${entry.key} in ${locale.languageCode}',
        (tester) async {
          for (final route in _staticRoutes) {
            await _pumpAt(
              tester,
              db,
              location: route,
              size: entry.value,
              locale: locale,
            );

            expect(
              tester.takeException(),
              isNull,
              reason: 'route $route threw at ${entry.key} '
                  '(${locale.languageCode})',
            );
            expect(
              find.byType(MaterialApp),
              findsOneWidget,
              reason: 'route $route did not build an app',
            );
          }
        },
      );
    }
  }

  testWidgets('an unknown route renders the not-found page', (tester) async {
    await _pumpAt(
      tester,
      db,
      location: '/this-route-does-not-exist',
      size: desktop,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Not found'), findsOneWidget);
  });

  testWidgets('a product detail route for a missing id does not crash', (
    tester,
  ) async {
    await _pumpAt(tester, db, location: '/products/999999', size: desktop);
    // The page is allowed to show an error state; it is not allowed to throw.
    expect(tester.takeException(), isNull);
  });
}
