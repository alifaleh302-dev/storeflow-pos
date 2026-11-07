import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

void main() {
  group('SQLite availability probe', () {
    // The probe exists so that a build which failed to bundle the native SQLite
    // library reports that fact instead of crashing inside the FFI bindings.
    // On a host that can run these tests the library is present, so the probe
    // must report no problem and the version must be readable.
    test('reports no problem when the native library is loaded', () {
      expect(checkSqliteAvailability(), isNull);
    });

    test('reports a usable SQLite version', () {
      expect(sqliteRuntimeVersion(), isNotEmpty);
      // "3.x.y" — assert the major version rather than an exact string so the
      // test does not break when the bundled SQLite is upgraded.
      expect(sqliteRuntimeVersion(), startsWith('3.'));
    });
  });
}
