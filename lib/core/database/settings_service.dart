
import '../../infrastructure/database/app_database.dart';
import '../constants/app_constants.dart';
import '../utils/timestamps.dart';

/// Typed access to the key/value `settings` table.
///
/// Values are stored as text; this service owns the conversions so that a
/// malformed value degrades to the caller's fallback instead of crashing.
class SettingsService {
  const SettingsService(this._db);

  final AppDatabase _db;

  Future<String?> getString(String key) async {
    final row = await (_db.select(_db.settings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<String> getStringOr(String key, String fallback) async =>
      (await getString(key)) ?? fallback;

  Future<void> setString(String key, String value) async {
    await _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(
            key: key,
            value: value,
            updatedAt: nowStorageTimestamp(),
          ),
        );
  }

  Future<bool> getBool(String key, {bool fallback = false}) async {
    final raw = await getString(key);
    if (raw == null) return fallback;
    return raw.toLowerCase() == 'true';
  }

  Future<void> setBool(String key, bool value) =>
      setString(key, value ? 'true' : 'false');

  Future<int> getInt(String key, {int fallback = 0}) async {
    final raw = await getString(key);
    if (raw == null) return fallback;
    return int.tryParse(raw) ?? fallback;
  }

  Future<void> setInt(String key, int value) => setString(key, value.toString());

  /// Reads every setting at once, for screens that display many values.
  Future<Map<String, String>> getAll() async {
    final rows = await _db.select(_db.settings).get();
    return {for (final row in rows) row.key: row.value};
  }

  /// Whether negative stock is permitted. Defaults to `false` per the
  /// inventory policy in the specification.
  Future<bool> allowNegativeStock() =>
      getBool(SettingsKeys.allowNegativeStock, fallback: false);

  /// The active UI locale code (`ar` or `en`). Arabic is the shipped default.
  Future<String> locale() => getStringOr(SettingsKeys.locale, 'ar');
}
