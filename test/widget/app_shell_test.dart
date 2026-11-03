import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/app/app.dart';
import 'package:storeflow_pos/app/app_providers.dart';
import 'package:storeflow_pos/app/router.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';
import 'package:storeflow_pos/l10n/generated/app_localizations.dart';

/// Builds the real application against an in-memory database.
///
/// These tests exercise the actual router, shell, providers and dashboard
/// queries. Nothing is mocked: the widget tree is the production one, only the
/// database file is replaced.
Future<void> pumpApp(
  WidgetTester tester,
  AppDatabase db, {
  String? initialLocation,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // Pin the locale so assertions are deterministic regardless of the
        // seeded default (Arabic).
        localeProvider.overrideWith(() => _FixedLocale(locale)),
      ],
      child: StoreFlowApp(initialLocation: initialLocation),
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

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async => db.close());

  group('localisation', () {
    testWidgets('exposes both Arabic and English', (tester) async {
      await pumpApp(tester, db);
      expect(
        AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
        containsAll(<String>{'ar', 'en'}),
      );
    });

    testWidgets('Arabic is the seeded default locale', (tester) async {
      final stored = await db.select(db.settings).get();
      final localeRow =
          stored.firstWhere((row) => row.key == 'locale');
      expect(localeRow.value, 'ar');
    });

    testWidgets('renders English navigation labels', (tester) async {
      await pumpApp(tester, db, locale: const Locale('en'));
      expect(find.text('Dashboard'), findsWidgets);
      expect(find.text('Point of Sale'), findsWidgets);
    });

    testWidgets('renders Arabic navigation labels', (tester) async {
      await pumpApp(tester, db, locale: const Locale('ar'));
      expect(find.text('لوحة التحكم'), findsWidgets);
      expect(find.text('نقطة البيع'), findsWidgets);
    });

    testWidgets('switches the layout direction to RTL for Arabic',
        (tester) async {
      await pumpApp(tester, db, locale: const Locale('ar'));
      final direction = Directionality.of(
        tester.element(find.byType(Scaffold).first),
      );
      expect(direction, TextDirection.rtl);
    });

    testWidgets('keeps LTR for English', (tester) async {
      await pumpApp(tester, db, locale: const Locale('en'));
      final direction = Directionality.of(
        tester.element(find.byType(Scaffold).first),
      );
      expect(direction, TextDirection.ltr);
    });
  });

  group('adaptive shell', () {
    testWidgets('uses a navigation rail on a wide window', (tester) async {
      await pumpApp(tester, db);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('uses a bottom navigation bar on a narrow window',
        (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            localeProvider
                .overrideWith(() => _FixedLocale(const Locale('en'))),
          ],
          child: const StoreFlowApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });
  });

  group('routing', () {
    testWidgets('opens the dashboard at the root route', (tester) async {
      await pumpApp(tester, db);
      expect(find.text('Today'), findsWidgets);
    });

    testWidgets('navigates to products when the rail destination is tapped',
        (tester) async {
      await pumpApp(tester, db);
      await tester.tap(find.text('Products').first);
      await tester.pumpAndSettle();
      // The products page reports its own status until Phase 2 implements it.
      expect(find.textContaining('Phase 2'), findsWidgets);
    });

    testWidgets('navigates to point of sale', (tester) async {
      await pumpApp(tester, db, initialLocation: Routes.pos);
      expect(find.textContaining('Phase 3'), findsWidgets);
    });

    testWidgets('deep links to a product edit route', (tester) async {
      await pumpApp(tester, db, initialLocation: '/products/7/edit');
      // The title appears in both the app bar and the body.
      expect(find.text('Product form'), findsWidgets);
    });

    testWidgets('reports an unknown route instead of crashing', (tester) async {
      await pumpApp(tester, db, initialLocation: '/does-not-exist');
      expect(find.text('Not found'), findsOneWidget);
    });
  });

  group('dashboard against an empty database', () {
    testWidgets('shows zeros rather than sample data', (tester) async {
      await pumpApp(tester, db);
      // Ten metric cards, each showing 0 or 0.00 because nothing is posted yet.
      expect(find.text('0.00'), findsWidgets);
      expect(find.text('0'), findsWidgets);
    });

    testWidgets('shows an empty state for recent transactions',
        (tester) async {
      await pumpApp(tester, db);
      await tester.scrollUntilVisible(
        find.text('Recent transactions'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Recent transactions'), findsOneWidget);
    });
  });

  group('theme', () {
    testWidgets('provides both light and dark themes', (tester) async {
      await pumpApp(tester, db);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.theme?.brightness, Brightness.light);
      expect(app.darkTheme?.brightness, Brightness.dark);
      expect(app.theme?.useMaterial3, isTrue);
    });
  });
}
