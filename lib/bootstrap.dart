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

  // Check the native SQLite library before anything touches the database, so a
  // packaging fault is reported as a packaging fault instead of an FFI crash.
  final sqliteProblem = checkSqliteAvailability();
  if (sqliteProblem != null) {
    debugPrint('Startup failed: SQLite is not available: $sqliteProblem');
    runApp(
      const _StartupFailureApp(
        title: 'Database engine unavailable',
        message: _missingSqliteMessage,
      ),
    );
    return;
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

/// Shown when the application starts but the SQLite native library was not
/// bundled into the package.
///
/// This is a build defect, not a data problem, so the message names the cause
/// and the exact fix rather than showing a stack trace.
const String _missingSqliteMessage =
    'The application package does not contain the SQLite native library, so '
    'the database cannot be opened.\n\n'
    'This happens when the application is built on a machine where Flutter\'s '
    'native-assets feature is switched off. SQLite is shipped to Android as a '
    'Dart native asset; with the feature off the library is simply left out of '
    'the APK.\n\n'
    'Rebuild with native assets enabled:\n'
    '    flutter config --enable-native-assets\n'
    '    flutter clean\n'
    '    flutter build apk --release';

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
  const _StartupFailureApp({
    required this.message,
    this.title = 'StoreFlow POS could not start',
  });

  /// Headline shown above the message.
  final String title;

  /// Explanation of the failure, shown selectable so it can be copied.
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 64),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(message, textAlign: TextAlign.center),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
