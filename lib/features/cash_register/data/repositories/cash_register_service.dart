import 'package:drift/drift.dart';

import '../../../../core/constants/enums.dart';
import '../../../../core/database/audit_service.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/money/rounding.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../infrastructure/database/app_database.dart';

/// A cash session with its computed totals.
class CashSessionSummary {
  const CashSessionSummary({
    required this.session,
    required this.openingBalanceMinor,
    required this.cashInMinor,
    required this.cashOutMinor,
  });

  final CashSessionRow session;
  final int openingBalanceMinor;

  /// Money that came into the drawer: cash sales and debt collections.
  final int cashInMinor;

  /// Money that left the drawer: expenses, supplier payments, withdrawals.
  final int cashOutMinor;

  /// What the drawer should hold if every recorded movement is correct.
  int get expectedCashMinor =>
      openingBalanceMinor + cashInMinor - cashOutMinor;

  /// Actual cash counted minus what was expected. Negative means the drawer is
  /// short.
  int get differenceMinor =>
      (session.actualCash ?? expectedCashMinor) - expectedCashMinor;
}

/// Opens, tracks and closes cash register sessions.
///
/// Only physical cash movements belong here. A bank transfer, a card payment or
/// a credit sale moves money in an accounting sense but never touches the
/// drawer, so none of them appear in a session's totals.
class CashRegisterService {
  CashRegisterService(
    this._db, {
    AuditService? audit,
  }) : _audit = audit ?? AuditService(_db);

  final AppDatabase _db;
  final AuditService _audit;

  /// Opens a session. Only one may be open at a time.
  Future<int> openSession({
    required int openingBalanceMinor,
    required int currencyId,
    String? notes,
    int? userId,
  }) async {
    if (openingBalanceMinor < 0) {
      throw const ValidationFailure(
        'An opening balance cannot be negative',
        field: 'openingBalance',
      );
    }
    final open = await currentSession();
    if (open != null) {
      throw ValidationFailure(
        'A cash session is already open',
        details: <String, Object?>{'sessionId': open.id},
      );
    }

    final timestamp = nowStorageTimestamp();
    final sessionId = await _db.into(_db.cashSessions).insert(
          CashSessionsCompanion.insert(
            openingBalance: openingBalanceMinor,
            currencyId: currencyId,
            userId: Value(userId),
            status: CashSessionStatus.open.wireValue,
            notes: Value(notes),
            openedAt: timestamp,
          ),
        );

    // The opening float is itself a drawer movement, so the session's totals are
    // complete without treating the opening balance as a special case.
    if (openingBalanceMinor > 0) {
      await _db.into(_db.cashTransactions).insert(
            CashTransactionsCompanion.insert(
              sessionId: sessionId,
              transactionType: CashTransactionType.opening.wireValue,
              amountBase: openingBalanceMinor,
              currencyId: currencyId,
              originalAmount: openingBalanceMinor,
              description: const Value('Opening float'),
              createdAt: timestamp,
            ),
          );
    }

    await _audit.log(
      action: 'cash_session.opened',
      entityType: 'cash_session',
      entityId: sessionId,
      description: 'Cash session opened',
      payload: <String, Object?>{'openingBalanceMinor': openingBalanceMinor},
      userId: userId,
    );

    return sessionId;
  }

  /// The session currently open, if any.
  Future<CashSessionRow?> currentSession() async {
    return (_db.select(_db.cashSessions)
          ..where((t) => t.status.equals(CashSessionStatus.open.wireValue))
          ..orderBy(<OrderClauseGenerator<$CashSessionsTable>>[
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  /// The open session, or a failure explaining that none is open.
  Future<CashSessionRow> requireOpenSession() async {
    final session = await currentSession();
    if (session == null) {
      throw const ValidationFailure(
        'No cash session is open',
        field: 'cashSessionId',
      );
    }
    return session;
  }

  /// Records a manual deposit or withdrawal.
  Future<void> recordMovement({
    required int sessionId,
    required CashTransactionType type,
    required int amountMinor,
    required int currencyId,
    int exchangeRateNumerator = 1,
    int exchangeRateDenominator = 1,
    String? description,
    int? userId,
  }) async {
    if (amountMinor <= 0) {
      throw const ValidationFailure(
        'A cash movement must be positive',
        field: 'amount',
      );
    }
    if (type.direction == 0) {
      throw const ValidationFailure(
        'A manual movement must be a deposit or a withdrawal',
        field: 'type',
      );
    }

    final session = await (_db.select(_db.cashSessions)
          ..where((t) => t.id.equals(sessionId)))
        .getSingleOrNull();
    if (session == null) {
      throw NotFoundFailure(
        'Cash session not found',
        details: <String, Object?>{'sessionId': sessionId},
      );
    }
    if (session.status != CashSessionStatus.open.wireValue) {
      throw const ValidationFailure(
        'This cash session is already closed',
        field: 'status',
      );
    }

    final baseAmount =
        mulDivRound(amountMinor, exchangeRateNumerator, exchangeRateDenominator);
    final signed = type.direction > 0 ? baseAmount : -baseAmount;

    await _db.transaction(() async {
      await _db.into(_db.cashTransactions).insert(
            CashTransactionsCompanion.insert(
              sessionId: sessionId,
              transactionType: type.wireValue,
              amountBase: signed,
              currencyId: currencyId,
              originalAmount: amountMinor,
              exchangeRateNumerator: Value(exchangeRateNumerator),
              exchangeRateDenominator: Value(exchangeRateDenominator),
              description: Value(description),
              createdAt: nowStorageTimestamp(),
            ),
          );

      await _audit.log(
        action: 'cash_session.movement',
        entityType: 'cash_session',
        entityId: sessionId,
        description: description ?? type.wireValue,
        payload: <String, Object?>{'amountBaseMinor': signed},
        userId: userId,
      );
    });
  }

  /// The totals for a session, computed from its movements.
  Future<CashSessionSummary> summary(int sessionId) async {
    final session = await (_db.select(_db.cashSessions)
          ..where((t) => t.id.equals(sessionId)))
        .getSingleOrNull();
    if (session == null) {
      throw NotFoundFailure(
        'Cash session not found',
        details: <String, Object?>{'sessionId': sessionId},
      );
    }

    final transactions = await (_db.select(_db.cashTransactions)
          ..where((t) => t.sessionId.equals(sessionId)))
        .get();

    var cashIn = 0;
    var cashOut = 0;
    for (final transaction in transactions) {
      if (transaction.transactionType ==
          CashTransactionType.opening.wireValue) {
        // The opening float is reported separately, so it is not counted twice.
        continue;
      }
      if (transaction.amountBase >= 0) {
        cashIn += transaction.amountBase;
      } else {
        cashOut += -transaction.amountBase;
      }
    }

    return CashSessionSummary(
      session: session,
      openingBalanceMinor: session.openingBalance,
      cashInMinor: cashIn,
      cashOutMinor: cashOut,
    );
  }

  /// Closes a session with the cash that was actually counted.
  Future<CashSessionSummary> closeSession({
    required int sessionId,
    required int actualCashMinor,
    String? notes,
    int? userId,
  }) async {
    if (actualCashMinor < 0) {
      throw const ValidationFailure(
        'Counted cash cannot be negative',
        field: 'actualCash',
      );
    }

    final session = await (_db.select(_db.cashSessions)
          ..where((t) => t.id.equals(sessionId)))
        .getSingleOrNull();
    if (session == null) {
      throw NotFoundFailure(
        'Cash session not found',
        details: <String, Object?>{'sessionId': sessionId},
      );
    }
    if (session.status != CashSessionStatus.open.wireValue) {
      throw const ValidationFailure(
        'This cash session is already closed',
        field: 'status',
      );
    }

    final current = await summary(sessionId);
    final expected = current.expectedCashMinor;
    final difference = actualCashMinor - expected;

    await _db.transaction(() async {
      await (_db.update(_db.cashSessions)
            ..where((t) => t.id.equals(sessionId)))
          .write(
        CashSessionsCompanion(
          closingBalance: Value(actualCashMinor),
          expectedCash: Value(expected),
          actualCash: Value(actualCashMinor),
          difference: Value(difference),
          status: Value(CashSessionStatus.closed.wireValue),
          notes: notes == null
              ? const Value.absent()
              : Value(session.notes == null
                  ? notes
                  : '${session.notes}\n$notes'),
          closedAt: Value(nowStorageTimestamp()),
        ),
      );

      await _audit.log(
        action: 'cash_session.closed',
        entityType: 'cash_session',
        entityId: sessionId,
        description: 'Cash session closed',
        payload: <String, Object?>{
          'expectedCashMinor': expected,
          'actualCashMinor': actualCashMinor,
          'differenceMinor': difference,
        },
        userId: userId,
      );
    });

    return summary(sessionId);
  }

  /// Past sessions, newest first.
  Future<List<CashSessionRow>> history({int limit = 50}) async {
    return (_db.select(_db.cashSessions)
          ..orderBy(<OrderClauseGenerator<$CashSessionsTable>>[
            (t) => OrderingTerm(expression: t.openedAt, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(limit))
        .get();
  }

  /// The movements recorded in a session.
  Future<List<CashTransactionRow>> movements(int sessionId) async {
    return (_db.select(_db.cashTransactions)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy(<OrderClauseGenerator<$CashTransactionsTable>>[
            (t) => OrderingTerm(expression: t.createdAt),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
  }
}
