import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../core/database/audit_service.dart';
import '../core/database/sequence_service.dart';
import '../core/database/settings_service.dart';
import '../infrastructure/database/app_database.dart';

/// The single application database instance.
///
/// Overridden in `bootstrap.dart` with the opened on-disk database, and in
/// tests with `AppDatabase.memory()`. Throwing by default means a test that
/// forgets the override fails loudly instead of silently creating a second
/// connection.
final databaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError(
    'databaseProvider must be overridden with an AppDatabase instance',
  );
});

final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(ref.watch(databaseProvider)),
);

final auditServiceProvider = Provider<AuditService>(
  (ref) => AuditService(ref.watch(databaseProvider)),
);

final sequenceServiceProvider = Provider<SequenceService>(
  (ref) => SequenceService(ref.watch(databaseProvider)),
);

/// Theme mode, persisted in the `settings` table.
///
/// [AsyncNotifier] so the UI can show the last known value while the read is
/// in flight and the persisted value once it arrives.
class ThemeModeController extends AsyncNotifier<ThemeMode> {
  @override
  Future<ThemeMode> build() async {
    final stored =
        await ref.watch(settingsServiceProvider).getString(SettingsKeys.themeMode);
    return _parse(stored);
  }

  Future<void> set(ThemeMode mode) async {
    state = AsyncData(mode);
    await ref
        .read(settingsServiceProvider)
        .setString(SettingsKeys.themeMode, _wire(mode));
  }

  static ThemeMode _parse(String? value) => switch (value) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String _wire(ThemeMode mode) => switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };
}

final themeModeProvider =
    AsyncNotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

/// Active locale, persisted in the `settings` table. Arabic ships as default.
class LocaleController extends AsyncNotifier<Locale> {
  @override
  Future<Locale> build() async {
    final stored = await ref.watch(settingsServiceProvider).locale();
    return Locale(stored);
  }

  Future<void> set(Locale locale) async {
    state = AsyncData(locale);
    await ref
        .read(settingsServiceProvider)
        .setString(SettingsKeys.locale, locale.languageCode);
  }
}

final localeProvider =
    AsyncNotifierProvider<LocaleController, Locale>(LocaleController.new);

/// Platform-adaptive layout breakpoint.
///
/// Below this width the shell uses bottom navigation and single-column forms;
/// at or above it, a permanent navigation rail and data tables. Chosen so that
/// a phone in landscape still gets the touch layout and a 1024x600 netbook
/// still gets the desktop layout.
const double kDesktopBreakpoint = 900;
