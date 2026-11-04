import 'package:drift/drift.dart';

import '../../../../core/constants/enums.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/utils/pagination.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../infrastructure/database/app_database.dart';
import '../../domain/entities/supplier.dart';

/// A supplier with its current balance.
class SupplierBalance {
  const SupplierBalance({
    required this.supplier,
    required this.balanceBaseMinor,
  });

  final Supplier supplier;

  /// Positive means the store owes the supplier. This is the mirror of a
  /// customer balance, where positive means the customer owes the store.
  final int balanceBaseMinor;

  bool get isOwed => balanceBaseMinor > 0;
}

/// Reads and writes supplier records and their account balances.
///
/// A supplier's balance is never stored as a single number. It is the sum of an
/// append-only ledger of account entries, so any balance can be explained by the
/// documents behind it and can be rebuilt if it is ever doubted.
class SupplierRepository {
  SupplierRepository(this._db);

  final AppDatabase _db;

  /// Creates a supplier and returns its id.
  Future<int> create({
    required String name,
    String? phone,
    String? email,
    String? address,
    String? notes,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationFailure('A supplier needs a name', field: 'name');
    }
    final timestamp = nowStorageTimestamp();
    return _db.into(_db.suppliers).insert(
          SuppliersCompanion.insert(
            name: trimmed,
            phone: Value(phone?.trim()),
            email: Value(email?.trim()),
            address: Value(address?.trim()),
            notes: Value(notes?.trim()),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
  }

  /// Updates a supplier. Only the fields given are changed.
  Future<void> update(
    int id, {
    String? name,
    String? phone,
    String? email,
    String? address,
    String? notes,
    bool? isActive,
  }) async {
    final existing = await findById(id);
    if (existing == null) {
      throw NotFoundFailure(
        'Supplier not found',
        details: <String, Object?>{'supplierId': id},
      );
    }
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isEmpty) {
      throw const ValidationFailure('A supplier needs a name', field: 'name');
    }
    await (_db.update(_db.suppliers)..where((t) => t.id.equals(id))).write(
      SuppliersCompanion(
        name: trimmed == null ? const Value.absent() : Value(trimmed),
        phone: phone == null ? const Value.absent() : Value(phone.trim()),
        email: email == null ? const Value.absent() : Value(email.trim()),
        address: address == null ? const Value.absent() : Value(address.trim()),
        notes: notes == null ? const Value.absent() : Value(notes.trim()),
        isActive: isActive == null ? const Value.absent() : Value(isActive),
        updatedAt: Value(nowStorageTimestamp()),
      ),
    );
  }

  /// Deactivates a supplier without deleting its history.
  Future<void> deactivate(int id) => update(id, isActive: false);

  Future<void> activate(int id) => update(id, isActive: true);

  Future<Supplier?> findById(int id) async {
    final row =
        await (_db.select(_db.suppliers)..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    return row == null ? null : _toEntity(row);
  }

  /// One page of suppliers, optionally filtered by name.
  Future<Page<Supplier>> search({
    String? searchTerm,
    bool includeInactive = false,
    PageRequest request = const PageRequest(),
  }) async {
    Expression<bool> predicate = _db.suppliers.id.isBiggerThanValue(0);
    if (!includeInactive) {
      predicate = predicate & _db.suppliers.isActive.equals(true);
    }
    final term = searchTerm?.trim();
    if (term != null && term.isNotEmpty) {
      final escaped = term
          .replaceAll(r'\', r'\\')
          .replaceAll('%', r'\%')
          .replaceAll('_', r'\_');
      predicate = predicate &
          _db.suppliers.name.like('%$escaped%', escapeChar: r'\');
    }

    final rows = await (_db.select(_db.suppliers)
          ..where((t) => predicate)
          ..orderBy(<OrderClauseGenerator<$SuppliersTable>>[
            (t) => OrderingTerm(expression: t.name),
          ])
          ..limit(request.effectiveLimit, offset: request.offset))
        .get();

    final countQuery = _db.selectOnly(_db.suppliers)
      ..addColumns(<Expression<Object>>[countAll()])
      ..where(predicate);
    final total = (await countQuery.getSingle()).read(countAll()) ?? 0;

    return Page<Supplier>(
      items: <Supplier>[for (final row in rows) _toEntity(row)],
      totalCount: total,
      request: request,
    );
  }

  /// Suppliers that are owed money, largest debt first.
  Future<List<SupplierBalance>> withOutstandingBalance() async {
    final rows = await _db.customSelect(
      '''
      SELECT s.id AS id, s.name AS name, s.phone AS phone, s.email AS email,
             s.address AS address, s.notes AS notes, s.is_active AS is_active,
             COALESCE(SUM(
               CASE WHEN e.direction = 'credit' THEN e.amount_minor
                    ELSE -e.amount_minor END
             ), 0) AS balance
      FROM suppliers s
      LEFT JOIN supplier_account_entries e ON e.supplier_id = s.id
      GROUP BY s.id
      HAVING balance > 0
      ORDER BY balance DESC
      ''',
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.suppliers,
        _db.supplierAccountEntries,
      },
    ).get();

    return <SupplierBalance>[
      for (final row in rows)
        SupplierBalance(
          supplier: Supplier(
            id: row.read<int>('id'),
            name: row.read<String>('name'),
            phone: row.read<String?>('phone'),
            email: row.read<String?>('email'),
            address: row.read<String?>('address'),
            notes: row.read<String?>('notes'),
            isActive: row.read<bool>('is_active'),
          ),
          balanceBaseMinor: row.read<int>('balance'),
        ),
    ];
  }

  /// What the store owes one supplier, in base-currency minor units.
  ///
  /// Positive means the store owes the supplier. Reconstructed from the account
  /// entries rather than read from a cached column.
  Future<int> balanceOf(int supplierId) async {
    // The two directions carry opposite signs, so the sign is resolved here
    // rather than in SQL, where a plain SUM would net them incorrectly.
    final entries = await (_db.select(_db.supplierAccountEntries)
          ..where((t) => t.supplierId.equals(supplierId)))
        .get();
    var balance = 0;
    for (final entry in entries) {
      if (entry.direction == LedgerDirection.credit.wireValue) {
        balance += entry.amountMinor;
      } else {
        balance -= entry.amountMinor;
      }
    }
    return balance;
  }

  /// The account statement for a supplier, oldest first.
  Future<List<SupplierAccountEntryRow>> statement(int supplierId) async {
    return (_db.select(_db.supplierAccountEntries)
          ..where((t) => t.supplierId.equals(supplierId))
          ..orderBy(<OrderClauseGenerator<$SupplierAccountEntriesTable>>[
            (t) => OrderingTerm(expression: t.createdAt),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
  }

  Supplier _toEntity(SupplierRow row) => Supplier(
        id: row.id,
        name: row.name,
        phone: row.phone,
        email: row.email,
        address: row.address,
        notes: row.notes,
        isActive: row.isActive,
      );
}
