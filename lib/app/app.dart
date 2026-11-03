import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/generated/app_localizations.dart';
import 'app_providers.dart';
import 'router.dart';
import 'theme/app_theme.dart';

/// Root application widget.
///
/// Owns the router instance so navigation state survives theme and locale
/// changes, and reads both from Riverpod so a settings change rebuilds the
/// whole tree consistently.
class StoreFlowApp extends ConsumerStatefulWidget {
  const StoreFlowApp({this.initialLocation, super.key});

  /// Overrides the first route, used by integration tests.
  final String? initialLocation;

  @override
  ConsumerState<StoreFlowApp> createState() => _StoreFlowAppState();
}

class _StoreFlowAppState extends ConsumerState<StoreFlowApp> {
  late final GoRouter _router =
      buildRouter(initialLocation: widget.initialLocation ?? Routes.dashboard);

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider).value ?? ThemeMode.system;
    final locale = ref.watch(localeProvider).value ?? const Locale('ar');

    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      themeMode: themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
