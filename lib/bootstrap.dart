import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/app_providers.dart';
import 'infrastructure/database/app_database.dart';

/// Opens the database, then runs the application.
///
/// Keeping startup in one place means the database is open and migrated before
/// any widget reads it. A failure to open the database is reported on screen
/// instead of leaving a half-initialised UI.
Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_isDesktop) {
    await _configureDesktopWindow();
  }

  try {
    final database = AppDatabase.open();
    // Force the first connection so schema creation and migrations complete
    // before the UI mounts.
    await database.customSelect('SELECT 1').get();
    runApp(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: const StoreFlowApp(),
      ),
    );
  } catch (error, stackTrace) {
    debugPrint('Startup failed: $error');
    debugPrintStack(stackTrace: stackTrace);
    runApp(_StartupFailureApp(message: error.toString()));
  }
}

bool get _isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Applies the desktop window size and minimum size.
///
/// Uses the nativeapi `Window` surface exported by window_manager 0.6, which
/// replaced the older global `windowManager` helper.
Future<void> _configureDesktopWindow() async {
  final window = WindowManager.instance.getCurrent();
  if (window == null) return;
  // nativeapi uses its own Size type; convert from Flutter's with the
  // SizeToNative extension exported by window_manager.
  window.minimumSize = const Size(900, 600).toNative();
  window.setSize(const Size(1280, 800).toNative(), false);
  window.center();
  window.title = 'StoreFlow POS';
  window.show();
  window.focus();
}

/// Minimal error screen used when startup itself fails.
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 64),
                const SizedBox(height: 16),
                const Text(
                  'StoreFlow POS could not start',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                SelectableText(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
