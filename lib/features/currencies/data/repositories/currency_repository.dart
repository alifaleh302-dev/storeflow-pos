import 'package:drift/drift.dart';

import '../../../../core/errors/failures.dart';
import '../../../../core/money/exchange_rate.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../infrastructure/database/app_database.dart';

/// A currency with its current rate against the base currency.
class CurrencyWithRate {
  const CurrencyWithRate({required this.currency, this.rate});

  final CurrencyRow currency;

  /// The rate in force right now. Null for the base currency, which is always
  /// the identity rate, and for a currency with no rate configured yet.
  final ExchangeRate? rate;

  ExchangeRate get effectiveRate => rate ?? ExchangeRate.identity;
}

/// Reads and writes currencies and their historical exchange rates.
///
/// ## Rates are historical, never overwritten
///
/// Changing a rate inserts a new row with a new effective date. The previous row
/// is left alone, so a rate can always be resolved as of any past moment and a
/// posted invoice keeps the rate it was written with. Nothing here rewrites a
/// rate that a transaction has already used.
class CurrencyRepository {
  CurrencyRepository(this._db);

  final AppDatabase _db;

  /// The base currency, which every other currency is priced against.
  Future<CurrencyRow> baseCurrency() async {
    final row = await (_db.select(_db.currencies)
          ..where((t) => t.isBase.equals(true))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) {
      throw const StorageFailure('No base currency is configured');
    }
    return row;
  }

  Future<CurrencyRow?> findById(int id) async {
    return (_db.select(_db.currencies)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<CurrencyRow?> findByCode(String code) async {
    return (_db.select(_db.currencies)
          ..where((t) => t.code.equals(code.trim().toUpperCase())))
        .getSingleOrNull();
  }

  /// All active currencies with their current rate, base currency first.
  Future<List<CurrencyWithRate>> active() async {
    final rows = await (_db.select(_db.currencies)
          ..where((t) => t.isActive.equals(true))
          ..orderBy(<OrderClauseGenerator<$CurrenciesTable>>[
            (t) => OrderingTerm(expression: t.isBase, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.code),
          ]))
        .get();

    final result = <CurrencyWithRate>[];
    for (final row in rows) {
      result.add(
        CurrencyWithRate(
          currency: row,
          rate: row.isBase ? null : await currentRate(row.id),
        ),
      );
    }
    return result;
  }

  /// Adds a currency. The first currency added becomes the base currency.
  Future<int> addCurrency({
    required String code,
    required String name,
    String? symbol,
    int decimalDigits = 2,
  }) async {
    final trimmedCode = code.trim().toUpperCase();
    if (trimmedCode.length < 2) {
      throw const ValidationFailure(
        'A currency code needs at least two characters',
        field: 'code',
      );
    }
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw const ValidationFailure('A currency needs a name', field: 'name');
    }
    if (decimalDigits < 0 || decimalDigits > 4) {
      throw const ValidationFailure(
        'Decimal digits must be between 0 and 4',
        field: 'decimalDigits',
      );
    }

    final existing = await findByCode(trimmedCode);
    if (existing != null) {
      throw ValidationFailure(
        'A currency with this code already exists',
        field: 'code',
        details: <String, Object?>{'code': trimmedCode},
      );
    }

    final anyCurrency = await _db.select(_db.currencies).get();
    final timestamp = nowStorageTimestamp();
    return _db.into(_db.currencies).insert(
          CurrenciesCompanion.insert(
            code: trimmedCode,
            name: trimmedName,
            symbol: Value(symbol?.trim()),
            decimalDigits: Value(decimalDigits),
            isBase: Value(anyCurrency.isEmpty),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
  }

  /// Renames a currency or changes its symbol.
  ///
  /// The code and the decimal precision are deliberately not editable. Either
  /// would reinterpret every amount already stored in that currency, and the
  /// precision is baked into the minor units of every historical row.
  Future<void> updateCurrency(
    int id, {
    String? name,
    String? symbol,
    bool? isActive,
  }) async {
    final existing = await findById(id);
    if (existing == null) {
      throw NotFoundFailure(
        'Currency not found',
        details: <String, Object?>{'currencyId': id},
      );
    }
    final trimmedName = name?.trim();
    if (trimmedName != null && trimmedName.isEmpty) {
      throw const ValidationFailure('A currency needs a name', field: 'name');
    }
    if (existing.isBase && isActive == false) {
      throw const ValidationFailure(
        'The base currency cannot be deactivated',
        field: 'isActive',
      );
    }

    await (_db.update(_db.currencies)..where((t) => t.id.equals(id))).write(
      CurrenciesCompanion(
        name: trimmedName == null ? const Value.absent() : Value(trimmedName),
        symbol: symbol == null ? const Value.absent() : Value(symbol.trim()),
        isActive: isActive == null ? const Value.absent() : Value(isActive),
        updatedAt: Value(nowStorageTimestamp()),
      ),
    );
  }

  /// Records a new rate for a currency.
  ///
  /// The previous rate is kept. The new one takes effect from [effectiveFrom],
  /// which defaults to now, so a rate entered for a past date resolves correctly
  /// for invoices dated after it.
  Future<int> setRate({
    required int currencyId,
    required int numerator,
    required int denominator,
    DateTime? effectiveFrom,
  }) async {
    final currency = await findById(currencyId);
    if (currency == null) {
      throw NotFoundFailure(
        'Currency not found',
        details: <String, Object?>{'currencyId': currencyId},
      );
    }
    if (currency.isBase) {
      throw const ValidationFailure(
        'The base currency always has a rate of one',
        field: 'currencyId',
      );
    }
    // Validated through the value object so the same rules apply everywhere.
    ExchangeRate(numerator: numerator, denominator: denominator);

    return _db.into(_db.exchangeRates).insert(
          ExchangeRatesCompanion.insert(
            currencyId: currencyId,
            numerator: numerator,
            denominator: denominator,
            effectiveFrom: toStorageTimestamp(effectiveFrom ?? DateTime.now()),
            createdAt: nowStorageTimestamp(),
          ),
        );
  }

  /// The rate in force for a currency at a given moment.
  ///
  /// The most recent rate whose effective date is at or before [asOf] wins. A
  /// rate entered for a future date is not used early.
  Future<ExchangeRate?> rateAt(int currencyId, DateTime asOf) async {
    final row = await (_db.select(_db.exchangeRates)
          ..where((t) =>
              t.currencyId.equals(currencyId) &
              t.effectiveFrom.isSmallerOrEqualValue(toStorageTimestamp(asOf)))
          ..orderBy(<OrderClauseGenerator<$ExchangeRatesTable>>[
            (t) => OrderingTerm(
                expression: t.effectiveFrom, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    return ExchangeRate(
      numerator: row.numerator,
      denominator: row.denominator,
    );
  }

  /// The rate in force now.
  Future<ExchangeRate?> currentRate(int currencyId) =>
      rateAt(currencyId, DateTime.now());

  /// The full rate history for a currency, newest first.
  Future<List<ExchangeRateRow>> rateHistory(int currencyId) async {
    return (_db.select(_db.exchangeRates)
          ..where((t) => t.currencyId.equals(currencyId))
          ..orderBy(<OrderClauseGenerator<$ExchangeRatesTable>>[
            (t) => OrderingTerm(
                expression: t.effectiveFrom, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ]))
        .get();
  }
}
