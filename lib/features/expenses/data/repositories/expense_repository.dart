import 'package:drift/drift.dart';

import '../../../../core/constants/enums.dart';
import '../../../../core/database/audit_service.dart';
import '../../../../core/database/sequence_service.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/money/rounding.dart';
import '../../../../core/utils/pagination.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../infrastructure/database/app_database.dart';

/// Reads and writes operating expenses.
///
/// An expense is money the business spends to keep running: rent, power,
/// salaries. It reduces net operating profit but is not a cost of goods sold, so
/// it must never be mixed into gross profit.
class ExpenseRepository {
  ExpenseRepository(
    this._db, {
    SequenceService? sequences,
    AuditService? audit,
  })  : _sequences = sequences ?? SequenceService(_db),
        _audit = audit ?? AuditService(_db);

  final AppDatabase _db;
  final SequenceService _sequences;
  final AuditService _audit;

  /// Records an expense.
  ///
  /// The amount is stored in the currency it was paid in together with the rate
  /// used, so the base-currency figure reflects the rate on the day and never
  /// moves when a rate is later changed.
  Future<String> record({
    required String description,
    required int amountMinor,
    required int currencyId,
    required PaymentMethod paymentMethod,
    int? categoryId,
    int exchangeRateNumerator = 1,
    int exchangeRateDenominator = 1,
    int? cashSessionId,
    int? supplierId,
    String? notes,
    DateTime? spentAt,
    int? userId,
  }) async {
    final trimmed = description.trim();
    if (trimmed.isEmpty) {
      throw const ValidationFailure(
        'An expense needs a description',
        field: 'description',
      );
    }
    if (amountMinor <= 0) {
      throw const ValidationFailure(
        'An expense must be positive',
        field: 'amount',
      );
    }
    if (exchangeRateNumerator <= 0 || exchangeRateDenominator <= 0) {
      throw const ValidationFailure(
        'Invalid exchange rate',
        field: 'exchangeRate',
      );
    }
    if (categoryId != null) {
      final category = await (_db.select(_db.expenseCategories)
            ..where((t) => t.id.equals(categoryId)))
          .getSingleOrNull();
      if (category == null) {
        throw NotFoundFailure(
          'Expense category not found',
          details: <String, Object?>{'categoryId': categoryId},
        );
      }
    }

    final baseAmount =
        mulDivRound(amountMinor, exchangeRateNumerator, exchangeRateDenominator);

    return _db.transaction(() async {
      final timestamp = toStorageTimestamp(spentAt ?? DateTime.now());
      final expenseNo = await _sequences.next('expense');

      await _db.into(_db.expenses).insert(
            ExpensesCompanion.insert(
              expenseNo: expenseNo,
              categoryId: Value(categoryId),
              description: trimmed,
              amount: amountMinor,
              currencyId: currencyId,
              exchangeRateNumerator: Value(exchangeRateNumerator),
              exchangeRateDenominator: Value(exchangeRateDenominator),
              baseAmount: baseAmount,
              paymentMethod: paymentMethod.wireValue,
              cashSessionId: Value(cashSessionId),
              supplierId: Value(supplierId),
              notes: Value(notes?.trim()),
              createdAt: timestamp,
            ),
          );

      // Paying an expense in cash takes money out of the drawer. A transfer or a
      // card payment is money spent, but not money that left the till.
      if (paymentMethod.isCash && cashSessionId != null) {
        await _db.into(_db.cashTransactions).insert(
              CashTransactionsCompanion.insert(
                sessionId: cashSessionId,
                transactionType: CashTransactionType.expensePayment.wireValue,
                amountBase: -baseAmount,
                currencyId: currencyId,
                originalAmount: amountMinor,
                exchangeRateNumerator: Value(exchangeRateNumerator),
                exchangeRateDenominator: Value(exchangeRateDenominator),
                referenceType: Value(ReferenceType.expense.wireValue),
                description: Value('Expense $expenseNo'),
                createdAt: timestamp,
              ),
            );
      }

      await _audit.log(
        action: 'expense.recorded',
        entityType: 'expense',
        entityId: null,
        description: 'Expense $expenseNo recorded',
        payload: <String, Object?>{
          'expenseNo': expenseNo,
          'amountMinor': amountMinor,
          'baseAmountMinor': baseAmount,
          'categoryId': categoryId,
        },
        userId: userId,
      );

      return expenseNo;
    });
  }

  /// One page of expenses, newest first.
  Future<Page<ExpenseRow>> search({
    ExpenseFilter filter = const ExpenseFilter(),
    PageRequest request = const PageRequest(),
  }) async {
    final rows = await (_db.select(_db.expenses)
          ..where((t) => _buildWhere(filter))
          ..orderBy(<OrderClauseGenerator<$ExpensesTable>>[
            (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(request.effectiveLimit, offset: request.offset))
        .get();

    final countQuery = _db.selectOnly(_db.expenses)
      ..addColumns(<Expression<Object>>[countAll()])
      ..where(_buildWhere(filter));
    final total = (await countQuery.getSingle()).read(countAll()) ?? 0;

    return Page<ExpenseRow>(
      items: rows,
      totalCount: total,
      request: request,
    );
  }

  /// Total operating expenses in base-currency minor units over a period.
  Future<int> totalBaseMinor({DateTime? from, DateTime? to}) async {
    final predicate = _periodPredicate(from: from, to: to);
    final query = _db.selectOnly(_db.expenses)
      ..addColumns(<Expression<Object>>[_db.expenses.baseAmount.sum()])
      ..where(predicate);
    final row = await query.getSingle();
    return row.read(_db.expenses.baseAmount.sum()) ?? 0;
  }

  /// Expense totals grouped by category over a period, largest first.
  Future<List<({int? categoryId, String? categoryName, int totalBaseMinor})>>
      totalsByCategory({DateTime? from, DateTime? to}) async {
    final predicate = _periodPredicate(from: from, to: to);
    final query = _db.selectOnly(_db.expenses)
      ..addColumns(<Expression<Object>>[
        _db.expenses.categoryId,
        _db.expenses.baseAmount.sum(),
      ])
      ..where(predicate)
      ..groupBy(<Expression<Object>>[_db.expenses.categoryId]);
    final rows = await query.get();

    final result =
        <({int? categoryId, String? categoryName, int totalBaseMinor})>[];
    for (final row in rows) {
      final categoryId = row.read(_db.expenses.categoryId);
      String? name;
      if (categoryId != null) {
        final category = await (_db.select(_db.expenseCategories)
              ..where((t) => t.id.equals(categoryId)))
            .getSingleOrNull();
        name = category?.name;
      }
      result.add((
        categoryId: categoryId,
        categoryName: name,
        totalBaseMinor: row.read(_db.expenses.baseAmount.sum()) ?? 0,
      ));
    }
    result.sort((a, b) => b.totalBaseMinor.compareTo(a.totalBaseMinor));
    return result;
  }

  /// The categories seeded at install, plus any the user added.
  Future<List<ExpenseCategoryRow>> categories() async {
    return (_db.select(_db.expenseCategories)
          ..where((t) => t.isActive.equals(true))
          ..orderBy(<OrderClauseGenerator<$ExpenseCategoriesTable>>[
            (t) => OrderingTerm(expression: t.name),
          ]))
        .get();
  }

  Expression<bool> _periodPredicate({DateTime? from, DateTime? to}) {
    Expression<bool> predicate = _db.expenses.id.isBiggerThanValue(0);
    if (from != null) {
      predicate = predicate &
          _db.expenses.createdAt
              .isBiggerOrEqualValue(toStorageTimestamp(from));
    }
    if (to != null) {
      predicate = predicate &
          _db.expenses.createdAt
              .isSmallerOrEqualValue(toStorageTimestamp(to));
    }
    return predicate;
  }

  Expression<bool> _buildWhere(ExpenseFilter filter) {
    var predicate = _periodPredicate(from: filter.from, to: filter.to);
    if (filter.categoryId != null) {
      predicate = predicate & _db.expenses.categoryId.equals(filter.categoryId!);
    }
    if (filter.currencyId != null) {
      predicate = predicate & _db.expenses.currencyId.equals(filter.currencyId!);
    }
    final term = filter.searchTerm?.trim();
    if (term != null && term.isNotEmpty) {
      final escaped = term
          .replaceAll(r'\', r'\\')
          .replaceAll('%', r'\%')
          .replaceAll('_', r'\_');
      predicate =
          predicate & _db.expenses.description.like('%$escaped%', escapeChar: r'\');
    }
    return predicate;
  }
}

/// Filters for the expense list.
class ExpenseFilter {
  const ExpenseFilter({
    this.searchTerm,
    this.categoryId,
    this.currencyId,
    this.from,
    this.to,
  });

  final String? searchTerm;
  final int? categoryId;
  final int? currencyId;
  final DateTime? from;
  final DateTime? to;
}
