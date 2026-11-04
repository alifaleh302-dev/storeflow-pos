import 'package:drift/drift.dart';

import '../../../../core/constants/enums.dart';
import '../../../../core/database/audit_service.dart';
import '../../../../core/database/sequence_service.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/money/rounding.dart';
import '../../../../core/utils/pagination.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../infrastructure/database/app_database.dart';

/// A customer with their current balance.
class CustomerBalance {
  const CustomerBalance({
    required this.customer,
    required this.balanceBaseMinor,
  });

  final CustomerRow customer;

  /// Positive means the customer owes the store. Reconstructed by summing the
  /// account ledger, never read from a cached column.
  final int balanceBaseMinor;

  bool get isInDebt => balanceBaseMinor > 0;

  /// A customer who has paid more than they owed, for example after a return.
  bool get isInCredit => balanceBaseMinor < 0;
}

/// Reads and writes customers, their payments and their account ledger.
///
/// A customer's balance is the sum of an append-only ledger. Nothing stores a
/// running total, so a balance can always be explained by the documents behind
/// it: a credit sale debits the account, a payment or a return credits it.
class CustomerRepository {
  CustomerRepository(
    this._db, {
    SequenceService? sequences,
    AuditService? audit,
  })  : _sequences = sequences ?? SequenceService(_db),
        _audit = audit ?? AuditService(_db);

  final AppDatabase _db;
  final SequenceService _sequences;
  final AuditService _audit;

  /// Creates a customer.
  Future<int> create({
    required String name,
    String? phone,
    String? address,
    String? notes,
    bool isWalkIn = false,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const ValidationFailure('A customer needs a name', field: 'name');
    }
    final timestamp = nowStorageTimestamp();
    return _db.into(_db.customers).insert(
          CustomersCompanion.insert(
            name: trimmed,
            phone: Value(phone?.trim()),
            address: Value(address?.trim()),
            notes: Value(notes?.trim()),
            isWalkIn: Value(isWalkIn),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
  }

  /// The default customer used when no specific customer is chosen.
  ///
  /// A shop needs somewhere to put a sale that has no named buyer, so one
  /// walk-in customer is reused rather than leaving the reference null.
  Future<int> walkInCustomerId() async {
    final existing = await (_db.select(_db.customers)
          ..where((t) => t.isWalkIn.equals(true))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return existing.id;
    return create(name: 'Walk-in Customer', isWalkIn: true);
  }

  Future<void> update(
    int id, {
    String? name,
    String? phone,
    String? address,
    String? notes,
    bool? isActive,
  }) async {
    final existing = await findById(id);
    if (existing == null) {
      throw NotFoundFailure(
        'Customer not found',
        details: <String, Object?>{'customerId': id},
      );
    }
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isEmpty) {
      throw const ValidationFailure('A customer needs a name', field: 'name');
    }
    await (_db.update(_db.customers)..where((t) => t.id.equals(id))).write(
      CustomersCompanion(
        name: trimmed == null ? const Value.absent() : Value(trimmed),
        phone: phone == null ? const Value.absent() : Value(phone.trim()),
        address: address == null ? const Value.absent() : Value(address.trim()),
        notes: notes == null ? const Value.absent() : Value(notes.trim()),
        isActive: isActive == null ? const Value.absent() : Value(isActive),
        updatedAt: Value(nowStorageTimestamp()),
      ),
    );
  }

  Future<void> deactivate(int id) => update(id, isActive: false);
  Future<void> activate(int id) => update(id, isActive: true);

  Future<CustomerRow?> findById(int id) async {
    return (_db.select(_db.customers)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// One page of customers, optionally filtered by name or phone.
  Future<Page<CustomerRow>> search({
    String? searchTerm,
    bool includeInactive = false,
    PageRequest request = const PageRequest(),
  }) async {
    Expression<bool> predicate = _db.customers.id.isBiggerThanValue(0);
    if (!includeInactive) {
      predicate = predicate & _db.customers.isActive.equals(true);
    }
    final term = searchTerm?.trim();
    if (term != null && term.isNotEmpty) {
      final escaped = _escapeLike(term);
      predicate = predicate &
          (_db.customers.name.like('%$escaped%', escapeChar: r'\') |
              _db.customers.phone.like('%$escaped%', escapeChar: r'\'));
    }

    final rows = await (_db.select(_db.customers)
          ..where((t) => predicate)
          ..orderBy(<OrderClauseGenerator<$CustomersTable>>[
            (t) => OrderingTerm(expression: t.name),
          ])
          ..limit(request.effectiveLimit, offset: request.offset))
        .get();

    final countQuery = _db.selectOnly(_db.customers)
      ..addColumns(<Expression<Object>>[countAll()])
      ..where(predicate);
    final total = (await countQuery.getSingle()).read(countAll()) ?? 0;

    return Page<CustomerRow>(
      items: rows,
      totalCount: total,
      request: request,
    );
  }

  /// What a customer owes, in base-currency minor units.
  ///
  /// Positive means the customer owes the store. Rebuilt from the ledger, so it
  /// stays correct even if a payment is recorded out of order.
  Future<int> balanceOf(int customerId) async {
    final entries = await (_db.select(_db.customerAccountEntries)
          ..where((t) => t.customerId.equals(customerId)))
        .get();
    var balance = 0;
    for (final entry in entries) {
      if (entry.direction == LedgerDirection.debit.wireValue) {
        balance += entry.amountMinor;
      } else {
        balance -= entry.amountMinor;
      }
    }
    return balance;
  }

  /// Customers who owe money, largest debt first.
  Future<List<CustomerBalance>> withOutstandingBalance() async {
    final rows = await _db.customers.all().get();
    final balances = <CustomerBalance>[];
    for (final row in rows) {
      final balance = await balanceOf(row.id);
      if (balance != 0) {
        balances.add(CustomerBalance(customer: row, balanceBaseMinor: balance));
      }
    }
    balances.sort((a, b) => b.balanceBaseMinor.compareTo(a.balanceBaseMinor));
    return balances;
  }

  /// The account statement, oldest first.
  Future<List<CustomerAccountEntryRow>> statement(int customerId) async {
    return (_db.select(_db.customerAccountEntries)
          ..where((t) => t.customerId.equals(customerId))
          ..orderBy(<OrderClauseGenerator<$CustomerAccountEntriesTable>>[
            (t) => OrderingTerm(expression: t.createdAt),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
  }

  /// Records a payment received from a customer.
  ///
  /// A payment is not a sale: it settles an existing debt and never creates new
  /// revenue. The money received is credited to the account, and a cash payment
  /// also adds to the drawer.
  Future<String> recordPayment({
    required int customerId,
    required PaymentMethod paymentMethod,
    required int currencyId,
    required int amountMinor,
    required int exchangeRateNumerator,
    required int exchangeRateDenominator,
    int? cashSessionId,
    String? notes,
    int? userId,
  }) async {
    if (amountMinor <= 0) {
      throw const ValidationFailure(
        'A payment must be positive',
        field: 'amount',
      );
    }
    if (paymentMethod.isCredit) {
      throw const ValidationFailure(
        'A payment cannot itself be a credit',
        field: 'paymentMethod',
      );
    }
    if (exchangeRateNumerator <= 0 || exchangeRateDenominator <= 0) {
      throw const ValidationFailure(
        'Invalid exchange rate',
        field: 'exchangeRate',
      );
    }

    final customer = await findById(customerId);
    if (customer == null) {
      throw NotFoundFailure(
        'Customer not found',
        details: <String, Object?>{'customerId': customerId},
      );
    }

    final baseAmount =
        mulDivRound(amountMinor, exchangeRateNumerator, exchangeRateDenominator);

    return _db.transaction(() async {
      final timestamp = nowStorageTimestamp();
      final paymentNo = await _sequences.next('customer_payment');

      await _db.into(_db.customerPayments).insert(
            CustomerPaymentsCompanion.insert(
              paymentNo: paymentNo,
              customerId: customerId,
              currencyId: currencyId,
              paymentMethod: paymentMethod.wireValue,
              amount: amountMinor,
              exchangeRateNumerator: Value(exchangeRateNumerator),
              exchangeRateDenominator: Value(exchangeRateDenominator),
              baseAmount: baseAmount,
              cashSessionId: Value(cashSessionId),
              notes: Value(notes),
              createdAt: timestamp,
            ),
          );

      // The ledger is what moves the balance; the payment row is the document.
      await _db.into(_db.customerAccountEntries).insert(
            CustomerAccountEntriesCompanion.insert(
              customerId: customerId,
              direction: LedgerDirection.credit.wireValue,
              amountMinor: baseAmount,
              currencyId: currencyId,
              exchangeRateNumerator: Value(exchangeRateNumerator),
              exchangeRateDenominator: Value(exchangeRateDenominator),
              referenceType: ReferenceType.customerPayment.wireValue,
              description: Value('Payment $paymentNo'),
              createdAt: timestamp,
            ),
          );

      if (paymentMethod.isCash && cashSessionId != null) {
        await _db.into(_db.cashTransactions).insert(
              CashTransactionsCompanion.insert(
                sessionId: cashSessionId,
                transactionType:
                    CashTransactionType.customerCollection.wireValue,
                amountBase: baseAmount,
                currencyId: currencyId,
                originalAmount: amountMinor,
                exchangeRateNumerator: Value(exchangeRateNumerator),
                exchangeRateDenominator: Value(exchangeRateDenominator),
                referenceType: Value(ReferenceType.customerPayment.wireValue),
                description: Value('Collection $paymentNo'),
                createdAt: timestamp,
              ),
            );
      }

      await _audit.log(
        action: 'customer.payment',
        entityType: 'customer_payment',
        entityId: customerId,
        description: 'Payment $paymentNo received',
        payload: <String, Object?>{
          'customerId': customerId,
          'amountMinor': amountMinor,
          'baseAmountMinor': baseAmount,
        },
        userId: userId,
      );

      return paymentNo;
    });
  }

  /// Pays a supplier, settling part of what the store owes.
  ///
  /// The mirror of a customer payment. It reduces the supplier payable and, when
  /// paid in cash, takes money out of the drawer.
  Future<String> recordSupplierPayment({
    required int supplierId,
    required PaymentMethod paymentMethod,
    required int currencyId,
    required int amountMinor,
    required int exchangeRateNumerator,
    required int exchangeRateDenominator,
    int? cashSessionId,
    String? notes,
    int? userId,
  }) async {
    if (amountMinor <= 0) {
      throw const ValidationFailure(
        'A payment must be positive',
        field: 'amount',
      );
    }
    if (paymentMethod.isCredit) {
      throw const ValidationFailure(
        'A payment cannot itself be a credit',
        field: 'paymentMethod',
      );
    }

    final supplier = await (_db.select(_db.suppliers)
          ..where((t) => t.id.equals(supplierId)))
        .getSingleOrNull();
    if (supplier == null) {
      throw NotFoundFailure(
        'Supplier not found',
        details: <String, Object?>{'supplierId': supplierId},
      );
    }

    final baseAmount =
        mulDivRound(amountMinor, exchangeRateNumerator, exchangeRateDenominator);

    return _db.transaction(() async {
      final timestamp = nowStorageTimestamp();
      final paymentNo = await _sequences.next('supplier_payment');

      await _db.into(_db.supplierPayments).insert(
            SupplierPaymentsCompanion.insert(
              paymentNo: paymentNo,
              supplierId: supplierId,
              currencyId: currencyId,
              paymentMethod: paymentMethod.wireValue,
              amount: amountMinor,
              exchangeRateNumerator: Value(exchangeRateNumerator),
              exchangeRateDenominator: Value(exchangeRateDenominator),
              baseAmount: baseAmount,
              cashSessionId: Value(cashSessionId),
              notes: Value(notes),
              createdAt: timestamp,
            ),
          );

      // A debit reduces what the store owes the supplier.
      await _db.into(_db.supplierAccountEntries).insert(
            SupplierAccountEntriesCompanion.insert(
              supplierId: supplierId,
              direction: LedgerDirection.debit.wireValue,
              amountMinor: baseAmount,
              currencyId: currencyId,
              exchangeRateNumerator: Value(exchangeRateNumerator),
              exchangeRateDenominator: Value(exchangeRateDenominator),
              referenceType: ReferenceType.supplierPayment.wireValue,
              description: Value('Payment $paymentNo'),
              createdAt: timestamp,
            ),
          );

      if (paymentMethod.isCash && cashSessionId != null) {
        await _db.into(_db.cashTransactions).insert(
              CashTransactionsCompanion.insert(
                sessionId: cashSessionId,
                transactionType: CashTransactionType.supplierPayment.wireValue,
                amountBase: -baseAmount,
                currencyId: currencyId,
                originalAmount: amountMinor,
                exchangeRateNumerator: Value(exchangeRateNumerator),
                exchangeRateDenominator: Value(exchangeRateDenominator),
                referenceType: Value(ReferenceType.supplierPayment.wireValue),
                description: Value('Payment $paymentNo'),
                createdAt: timestamp,
              ),
            );
      }

      await _audit.log(
        action: 'supplier.payment',
        entityType: 'supplier_payment',
        entityId: supplierId,
        description: 'Payment $paymentNo made',
        payload: <String, Object?>{
          'supplierId': supplierId,
          'amountMinor': amountMinor,
          'baseAmountMinor': baseAmount,
        },
        userId: userId,
      );

      return paymentNo;
    });
  }

  String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}
