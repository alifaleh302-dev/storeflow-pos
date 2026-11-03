import 'package:drift/drift.dart';

import '../../infrastructure/database/app_database.dart';
import '../utils/timestamps.dart';

/// Allocates human-readable, gap-free document numbers.
///
/// Counters live in the `document_sequences` table, so numbering survives a
/// restart and two concurrent callers cannot produce the same number. Every
/// call must run inside the caller's transaction; if that transaction rolls
/// back, the counter increment rolls back with it and the number is not burned.
class SequenceService {
  const SequenceService(this._db);

  final AppDatabase _db;

  /// Reserved sequence names, each with its prefix and zero-padding width.
  static const Map<String, (String, int)> definitions = <String, (String, int)>{
    'sale': ('INV', 6),
    'sales_return': ('SR', 6),
    'purchase': ('PUR', 6),
    'purchase_return': ('PR', 6),
    'customer_payment': ('CP', 6),
    'supplier_payment': ('SP', 6),
    'expense': ('EXP', 6),
    'stock_adjustment': ('ADJ', 6),
    'customer': ('CUS', 5),
    'supplier': ('SUP', 5),
    'product': ('PRD', 6),
  };

  /// Returns the next number for [name], formatted as `PREFIX-000123`.
  ///
  /// Throws [ArgumentError] when [name] is not one of [definitions], which
  /// prevents a typo from silently creating an unformatted counter.
  Future<String> next(String name) async {
    final definition = definitions[name];
    if (definition == null) {
      throw ArgumentError.value(name, 'name', 'Unknown document sequence');
    }
    final (prefix, width) = definition;

    final existing = await (_db.select(_db.documentSequences)
          ..where((t) => t.name.equals(name)))
        .getSingleOrNull();

    final int nextValue;
    if (existing == null) {
      nextValue = 1;
      await _db.into(_db.documentSequences).insert(
            DocumentSequencesCompanion.insert(
              name: name,
              prefix: prefix,
              currentValue: Value(nextValue),
              updatedAt: nowStorageTimestamp(),
            ),
          );
    } else {
      nextValue = existing.currentValue + 1;
      await (_db.update(_db.documentSequences)
            ..where((t) => t.name.equals(name)))
          .write(
        DocumentSequencesCompanion(
          currentValue: Value(nextValue),
          updatedAt: Value(nowStorageTimestamp()),
        ),
      );
    }
    return format(prefix, nextValue, width);
  }

  /// Formats a document number without touching the database.
  static String format(String prefix, int value, int width) {
    final padded = value.toString().padLeft(width, '0');
    return '$prefix-$padded';
  }

  /// The next value that would be issued, for previewing in forms.
  Future<int> peek(String name) async {
    final existing = await (_db.select(_db.documentSequences)
          ..where((t) => t.name.equals(name)))
        .getSingleOrNull();
    return (existing?.currentValue ?? 0) + 1;
  }

  /// Resets all counters. Only used by the restore flow after replacing the
  /// database, never during normal operation.
  Future<void> resetAll() async {
    await _db.delete(_db.documentSequences).go();
  }
}
