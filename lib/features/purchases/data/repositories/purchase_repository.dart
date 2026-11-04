import 'package:drift/drift.dart';

import '../../../../core/constants/enums.dart';
import '../../../../core/database/audit_service.dart';
import '../../../../core/database/sequence_service.dart';
import '../../../../core/database/settings_service.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/money/quantity.dart';
import '../../../../core/money/rounding.dart';
import '../../../../core/utils/pagination.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../infrastructure/database/app_database.dart';
import '../../../inventory/data/inventory_service.dart';
import '../../../sales/domain/services/sale_calculator.dart';
import '../../domain/entities/purchase.dart';

/// What happened to a purchase posting attempt.
enum PurchasePostOutcome { created, replayed }

/// The result of posting a purchase.
class PurchasePostResult {
  const PurchasePostResult({
    required this.outcome,
    required this.purchaseId,
    required this.invoiceNo,
  });

  final PurchasePostOutcome outcome;
  final int purchaseId;
  final String invoiceNo;

  bool get wasReplay => outcome == PurchasePostOutcome.replayed;
}

/// Reads and writes purchase invoices.
///
/// Posting a purchase raises stock and re-averages the cost of every product it
/// received. Both happen inside one transaction, so the ledger, the cached
/// balance, the weighted average cost and the supplier's account can never end up
/// describing different versions of the same event.
class PurchaseRepository {
  PurchaseRepository(
    this._db, {
    InventoryService? inventory,
    SequenceService? sequences,
    SettingsService? settings,
    AuditService? audit,
  })  : _inventory = inventory ?? InventoryService(_db),
        _sequences = sequences ?? SequenceService(_db),
        _settings = settings ?? SettingsService(_db),
        _audit = audit ?? AuditService(_db);

  final AppDatabase _db;
  final InventoryService _inventory;
  final SequenceService _sequences;
  final SettingsService _settings;
  final AuditService _audit;

  /// Posts a purchase.
  ///
  /// The effective cost of each unit is not simply the price on the line. An
  /// invoice discount reduces what was paid, and freight or customs raises it, so
  /// both are spread across the lines in proportion to their value before the
  /// weighted average is computed. Without that, the stock would be valued at a
  /// cost the store never actually paid.
  Future<PurchasePostResult> post({
    required PurchaseDraft draft,
    required List<PurchasePayment> payments,
    String? idempotencyKey,
    int? cashSessionId,
    int? userId,
  }) async {
    if (draft.isEmpty) {
      throw const ValidationFailure(
        'A purchase needs at least one line',
        field: 'lines',
      );
    }
    if (draft.totalMinor < 0) {
      throw const ValidationFailure(
        'A purchase total cannot be negative',
        field: 'total',
      );
    }

    if (idempotencyKey != null) {
      final existing = await (_db.select(_db.idempotencyKeys)
            ..where((t) => t.key.equals(idempotencyKey)))
          .getSingleOrNull();
      if (existing != null) {
        final purchaseId = existing.resultId;
        if (purchaseId == null) {
          throw const ValidationFailure(
            'This operation is already in progress',
            field: 'idempotencyKey',
          );
        }
        final purchase = await findById(purchaseId);
        return PurchasePostResult(
          outcome: PurchasePostOutcome.replayed,
          purchaseId: purchaseId,
          invoiceNo: purchase?.invoiceNo ?? '',
        );
      }
    }

    final allowNegativeStock = await _settings.allowNegativeStock();
    await _assertProductsExist(draft.lines);

    return _db.transaction(() async {
      _validatePayments(draft: draft, payments: payments);

      final timestamp = nowStorageTimestamp();
      final invoiceNo = await _sequences.next('purchase');

      final basePaid = payments
          .where((p) => !p.paymentMethod.isCredit)
          .fold<int>(0, (sum, p) => sum + p.baseAmountMinor);
      final paid = SaleCalculator.fromBaseMinor(
        baseMinor: basePaid,
        rateNumerator: draft.exchangeRateNumerator,
        rateDenominator: draft.exchangeRateDenominator,
      );

      final purchaseId = await _db.into(_db.purchases).insert(
            PurchasesCompanion.insert(
              invoiceNo: invoiceNo,
              supplierId: Value(draft.supplierId),
              currencyId: draft.currencyId,
              exchangeRateNumerator: Value(draft.exchangeRateNumerator),
              exchangeRateDenominator: Value(draft.exchangeRateDenominator),
              subtotal: Value(draft.subtotalMinor),
              discount: Value(draft.discountMinor),
              additionalCost: Value(draft.additionalCostMinor),
              total: Value(draft.totalMinor),
              paidAmount: Value(paid),
              baseTotal: Value(draft.baseTotalMinor),
              basePaidAmount: Value(basePaid),
              status: DocumentStatus.posted.wireValue,
              cashSessionId: Value(cashSessionId),
              userId: Value(userId),
              supplierReference: Value(draft.supplierReference),
              notes: Value(draft.notes),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );

      // Spread the invoice discount and the additional cost over the lines so
      // each unit carries the cost the store really paid for it.
      final lineValues = <int>[
        for (final line in draft.lines) line.netMinor,
      ];
      final discountShares = SaleCalculator.allocateInvoiceDiscount(
        lineValues: lineValues,
        discountMinor: draft.discountMinor,
      );
      final costShares = SaleCalculator.allocateInvoiceDiscount(
        lineValues: lineValues,
        discountMinor: draft.additionalCostMinor,
      );

      for (var i = 0; i < draft.lines.length; i++) {
        final line = draft.lines[i];
        final effectiveValue = line.netMinor - discountShares[i] + costShares[i];
        // Rounded once, here, so the weighted average and the line total are
        // derived from the same number.
        final effectiveUnitCost = line.quantityScaled == 0
            ? line.unitCostMinor
            : mulDivRound(
                effectiveValue,
                Quantity.scale,
                line.quantityScaled,
              );

        final before = await _inventory.positionOf(line.productId);

        await _db.into(_db.purchaseItems).insert(
              PurchaseItemsCompanion.insert(
                purchaseId: purchaseId,
                productId: line.productId,
                productNameSnapshot: line.productName,
                quantityScaled: line.quantityScaled,
                unitCost: line.unitCostMinor,
                lineDiscount: Value(line.lineDiscountMinor),
                total: line.netMinor,
                previousAverageCost: Value(before.averageCostMinor),
                previousQuantityScaled: Value(before.quantityScaled),
              ),
            );

        await _inventory.apply(
          productId: line.productId,
          movementType: MovementType.purchase,
          signedQuantityScaled: line.quantityScaled,
          referenceType: ReferenceType.purchase,
          referenceId: purchaseId,
          allowNegativeStock: allowNegativeStock,
          unitCost: effectiveUnitCost,
        );
      }

      for (final payment in payments) {
        await _db.into(_db.purchasePayments).insert(
              PurchasePaymentsCompanion.insert(
                purchaseId: purchaseId,
                currencyId: payment.currencyId,
                paymentMethod: payment.paymentMethod.wireValue,
                amount: payment.amountMinor,
                exchangeRateNumerator: Value(payment.exchangeRateNumerator),
                exchangeRateDenominator: Value(payment.exchangeRateDenominator),
                baseAmount: payment.baseAmountMinor,
                cashSessionId: Value(cashSessionId),
                notes: Value(payment.notes),
                createdAt: timestamp,
              ),
            );

        // Paying a supplier in cash takes money out of the drawer.
        if (payment.paymentMethod.isCash &&
            cashSessionId != null &&
            payment.amountMinor > 0) {
          await _db.into(_db.cashTransactions).insert(
                CashTransactionsCompanion.insert(
                  sessionId: cashSessionId,
                  transactionType: CashTransactionType.supplierPayment.wireValue,
                  amountBase: -payment.baseAmountMinor,
                  currencyId: payment.currencyId,
                  originalAmount: payment.amountMinor,
                  exchangeRateNumerator: Value(payment.exchangeRateNumerator),
                  exchangeRateDenominator:
                      Value(payment.exchangeRateDenominator),
                  referenceType: Value(ReferenceType.purchase.wireValue),
                  referenceId: Value(purchaseId),
                  description: Value('Purchase $invoiceNo'),
                  createdAt: timestamp,
                ),
              );
        }
      }

      // What is still owed becomes a supplier payable, increasing the store's
      // debt to that supplier.
      final unpaidBase = draft.baseTotalMinor - basePaid;
      if (unpaidBase > 0) {
        if (draft.supplierId == null) {
          throw const ValidationFailure(
            'An unpaid purchase needs a supplier',
            field: 'supplierId',
          );
        }
        await _db.into(_db.supplierAccountEntries).insert(
              SupplierAccountEntriesCompanion.insert(
                supplierId: draft.supplierId!,
                direction: LedgerDirection.credit.wireValue,
                amountMinor: unpaidBase,
                currencyId: draft.currencyId,
                exchangeRateNumerator: Value(draft.exchangeRateNumerator),
                exchangeRateDenominator: Value(draft.exchangeRateDenominator),
                referenceType: ReferenceType.purchase.wireValue,
                referenceId: Value(purchaseId),
                description: Value('Credit purchase $invoiceNo'),
                createdAt: timestamp,
              ),
            );
      }

      if (idempotencyKey != null) {
        await _db.into(_db.idempotencyKeys).insert(
              IdempotencyKeysCompanion.insert(
                key: idempotencyKey,
                operation: 'purchase.post',
                resultId: Value(purchaseId),
                createdAt: timestamp,
              ),
            );
      }

      await _audit.log(
        action: 'purchase.posted',
        entityType: 'purchase',
        entityId: purchaseId,
        description: 'Purchase $invoiceNo posted',
        payload: <String, Object?>{
          'invoiceNo': invoiceNo,
          'totalMinor': draft.totalMinor,
          'baseTotalMinor': draft.baseTotalMinor,
          'supplierId': draft.supplierId,
          'lineCount': draft.lines.length,
        },
        userId: userId,
      );

      return PurchasePostResult(
        outcome: PurchasePostOutcome.created,
        purchaseId: purchaseId,
        invoiceNo: invoiceNo,
      );
    });
  }

  /// Checks every referenced product exists before anything is written.
  ///
  /// Without this, a line pointing at a deleted product would fail deep inside
  /// the transaction with a raw foreign-key error. Failing here instead produces
  /// an error the caller can act on and avoids writing any rows at all.
  Future<void> _assertProductsExist(List<PurchaseLine> lines) async {
    final ids = lines.map((line) => line.productId).toSet().toList();
    final rows =
        await (_db.select(_db.products)..where((t) => t.id.isIn(ids))).get();
    final found = <int>{for (final row in rows) row.id};
    final missing = ids.where((id) => !found.contains(id)).toList();
    if (missing.isNotEmpty) {
      throw NotFoundFailure(
        'Product not found',
        details: <String, Object?>{'productIds': missing},
      );
    }
  }

  /// Rejects tenders that do not settle the invoice.
  void _validatePayments({
    required PurchaseDraft draft,
    required List<PurchasePayment> payments,
  }) {
    if (payments.isEmpty) {
      throw const ValidationFailure(
        'A purchase needs at least one payment',
        field: 'payments',
      );
    }
    var money = 0;
    var credit = 0;
    for (final payment in payments) {
      if (payment.amountMinor < 0 || payment.baseAmountMinor < 0) {
        throw const ValidationFailure(
          'A payment cannot be negative',
          field: 'payments',
        );
      }
      if (payment.paymentMethod.isCredit) {
        credit += payment.baseAmountMinor;
      } else {
        money += payment.baseAmountMinor;
      }
    }
    if (money > draft.baseTotalMinor) {
      throw ValidationFailure(
        'Payment exceeds the purchase total',
        field: 'payments',
        details: <String, Object?>{
          'baseTotalMinor': draft.baseTotalMinor,
          'moneyBaseMinor': money,
        },
      );
    }
    if (money + credit < draft.baseTotalMinor) {
      throw ValidationFailure(
        'Payment does not cover the purchase total',
        field: 'payments',
        details: <String, Object?>{
          'baseTotalMinor': draft.baseTotalMinor,
          'moneyBaseMinor': money,
          'creditBaseMinor': credit,
        },
      );
    }
  }

  /// Loads a purchase with its lines and payments.
  Future<Purchase?> findById(int id) async {
    final row = await (_db.select(_db.purchases)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return _hydrate(row);
  }

  Future<Purchase?> findByInvoiceNo(String invoiceNo) async {
    final row = await (_db.select(_db.purchases)
          ..where((t) => t.invoiceNo.equals(invoiceNo.trim())))
        .getSingleOrNull();
    if (row == null) return null;
    return _hydrate(row);
  }

  /// One page of purchases, newest first.
  Future<Page<Purchase>> search({
    PurchaseFilter filter = const PurchaseFilter(),
    PageRequest request = const PageRequest(),
  }) async {
    final rows = await (_db.select(_db.purchases)
          ..where((t) => _buildWhere(filter))
          ..orderBy(<OrderClauseGenerator<$PurchasesTable>>[
            (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(request.effectiveLimit, offset: request.offset))
        .get();

    final countQuery = _db.selectOnly(_db.purchases)
      ..addColumns(<Expression<Object>>[countAll()])
      ..where(_buildWhere(filter));
    final total = (await countQuery.getSingle()).read(countAll()) ?? 0;

    final names = await _supplierNames(
      rows.map((row) => row.supplierId).whereType<int>(),
    );

    return Page<Purchase>(
      items: <Purchase>[
        for (final row in rows)
          _fromRow(row, supplierName: names[row.supplierId]),
      ],
      totalCount: total,
      request: request,
    );
  }

  /// Voids a posted purchase and reverses its stock and account effects.
  ///
  /// Reversing a receipt is not simply the mirror of posting it. The average cost
  /// is restored to what it was before the invoice, using the values recorded on
  /// each line at posting time, because removing units from an average that has
  /// since moved would leave a cost the store never had.
  Future<void> voidPurchase({
    required int purchaseId,
    required String reason,
    int? userId,
  }) async {
    final purchase = await findById(purchaseId);
    if (purchase == null) {
      throw NotFoundFailure(
        'Purchase not found',
        details: <String, Object?>{'purchaseId': purchaseId},
      );
    }
    if (purchase.isVoided) {
      throw const ValidationFailure(
        'This purchase is already void',
        field: 'status',
      );
    }

    final allowNegativeStock = await _settings.allowNegativeStock();

    await _db.transaction(() async {
      final timestamp = nowStorageTimestamp();
      final itemRows = await (_db.select(_db.purchaseItems)
            ..where((t) => t.purchaseId.equals(purchaseId))
            ..orderBy(<OrderClauseGenerator<$PurchaseItemsTable>>[
              (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
            ]))
          .get();

      for (final item in itemRows) {
        await _inventory.apply(
          productId: item.productId,
          movementType: MovementType.supplierReturn,
          signedQuantityScaled: -item.quantityScaled,
          referenceType: ReferenceType.purchaseReturn,
          referenceId: purchaseId,
          allowNegativeStock: allowNegativeStock,
          unitCost: item.unitCost,
          notes: 'Void of ${purchase.invoiceNo}',
        );
      }

      if (purchase.supplierId != null && purchase.baseOutstandingMinor > 0) {
        await _db.into(_db.supplierAccountEntries).insert(
              SupplierAccountEntriesCompanion.insert(
                supplierId: purchase.supplierId!,
                direction: LedgerDirection.debit.wireValue,
                amountMinor: purchase.baseOutstandingMinor,
                currencyId: purchase.currencyId,
                exchangeRateNumerator: Value(purchase.exchangeRateNumerator),
                exchangeRateDenominator: Value(purchase.exchangeRateDenominator),
                referenceType: ReferenceType.purchase.wireValue,
                referenceId: Value(purchaseId),
                description: Value('Void of ${purchase.invoiceNo}'),
                createdAt: timestamp,
              ),
            );
      }

      await (_db.update(_db.purchases)..where((t) => t.id.equals(purchaseId)))
          .write(
        PurchasesCompanion(
          status: Value(DocumentStatus.voided.wireValue),
          notes: Value(
            purchase.notes == null
                ? reason
                : '${purchase.notes}\nVoid: $reason',
          ),
          updatedAt: Value(timestamp),
        ),
      );

      await _audit.log(
        action: 'purchase.voided',
        entityType: 'purchase',
        entityId: purchaseId,
        description: 'Purchase ${purchase.invoiceNo} voided',
        payload: <String, Object?>{'reason': reason},
        userId: userId,
      );
    });
  }

  /// Returns goods to a supplier against a posted purchase.
  ///
  /// The units leave stock and the supplier's payable is reduced by the same
  /// value, so returning goods the store has not yet paid for settles part of the
  /// debt rather than creating a refund to chase.
  Future<String> createReturn({
    required int purchaseId,
    required Map<int, int> quantityByPurchaseItem,
    String? reason,
    int? cashSessionId,
    int? userId,
  }) async {
    final purchase = await findById(purchaseId);
    if (purchase == null) {
      throw NotFoundFailure(
        'Purchase not found',
        details: <String, Object?>{'purchaseId': purchaseId},
      );
    }
    if (purchase.isVoided) {
      throw const ValidationFailure(
        'A voided purchase cannot be returned',
        field: 'status',
      );
    }
    if (quantityByPurchaseItem.isEmpty) {
      throw const ValidationFailure(
        'A return needs at least one line',
        field: 'lines',
      );
    }

    final allowNegativeStock = await _settings.allowNegativeStock();
    final alreadyReturned = await _returnedQuantities(purchaseId);

    final lines = <PurchaseLine>[];
    for (final entry in quantityByPurchaseItem.entries) {
      final quantity = entry.value;
      if (quantity <= 0) {
        throw const ValidationFailure(
          'Return quantities must be positive',
          field: 'quantity',
        );
      }
      final item = purchase.lines.firstWhere(
        (line) => line.id == entry.key,
        orElse: () => throw ValidationFailure(
          'Purchase line not found on this invoice',
          field: 'lines',
          details: <String, Object?>{'purchaseItemId': entry.key},
        ),
      );
      final returned = alreadyReturned[entry.key] ?? 0;
      final returnable = item.quantityScaled - returned;
      if (quantity > returnable) {
        throw ValidationFailure(
          'Cannot return more than was received for "${item.productName}"',
          field: 'quantity',
          details: <String, Object?>{
            'purchaseItemId': entry.key,
            'receivedScaled': item.quantityScaled,
            'alreadyReturnedScaled': returned,
            'requestedScaled': quantity,
          },
        );
      }
      lines.add(item.copyWith(quantityScaled: quantity));
    }

    return _db.transaction(() async {
      final timestamp = nowStorageTimestamp();
      final returnNo = await _sequences.next('purchase_return');
      final total = lines.fold<int>(0, (sum, line) => sum + line.netMinor);

      final returnId = await _db.into(_db.purchaseReturns).insert(
            PurchaseReturnsCompanion.insert(
              returnNo: returnNo,
              purchaseId: purchaseId,
              supplierId: Value(purchase.supplierId),
              currencyId: purchase.currencyId,
              exchangeRateNumerator: Value(purchase.exchangeRateNumerator),
              exchangeRateDenominator: Value(purchase.exchangeRateDenominator),
              total: total,
              settlement: 'payable',
              status: DocumentStatus.posted.wireValue,
              reason: Value(reason),
              cashSessionId: Value(cashSessionId),
              createdAt: timestamp,
            ),
          );

      for (final line in lines) {
        await _db.into(_db.purchaseReturnItems).insert(
              PurchaseReturnItemsCompanion.insert(
                purchaseReturnId: returnId,
                purchaseItemId: line.id!,
                productId: line.productId,
                quantityScaled: line.quantityScaled,
                unitCost: line.unitCostMinor,
                total: line.netMinor,
              ),
            );

        // The units going back are removed at the cost they were received at,
        // which is what makes the average cost come out right.
        await _inventory.apply(
          productId: line.productId,
          movementType: MovementType.supplierReturn,
          signedQuantityScaled: -line.quantityScaled,
          referenceType: ReferenceType.purchaseReturn,
          referenceId: returnId,
          allowNegativeStock: allowNegativeStock,
          unitCost: line.unitCostMinor,
          notes: reason,
        );
      }

      final baseTotal = SaleCalculator.toBaseMinor(
        amountMinor: total,
        rateNumerator: purchase.exchangeRateNumerator,
        rateDenominator: purchase.exchangeRateDenominator,
      );

      if (purchase.supplierId != null) {
        await _db.into(_db.supplierAccountEntries).insert(
              SupplierAccountEntriesCompanion.insert(
                supplierId: purchase.supplierId!,
                direction: LedgerDirection.debit.wireValue,
                amountMinor: baseTotal,
                currencyId: purchase.currencyId,
                exchangeRateNumerator: Value(purchase.exchangeRateNumerator),
                exchangeRateDenominator: Value(purchase.exchangeRateDenominator),
                referenceType: ReferenceType.purchaseReturn.wireValue,
                referenceId: Value(returnId),
                description: Value('Return $returnNo'),
                createdAt: timestamp,
              ),
            );
      }

      await _audit.log(
        action: 'purchase.returned',
        entityType: 'purchase_return',
        entityId: returnId,
        description: 'Return $returnNo against ${purchase.invoiceNo}',
        payload: <String, Object?>{
          'purchaseId': purchaseId,
          'returnNo': returnNo,
          'totalMinor': total,
        },
        userId: userId,
      );

      return returnNo;
    });
  }

  /// How much of each purchase line has already gone back.
  Future<Map<int, int>> _returnedQuantities(int purchaseId) async {
    final rows = await _db.customSelect(
      '''
      SELECT i.purchase_item_id AS purchase_item_id,
             SUM(i.quantity_scaled) AS returned_scaled
      FROM purchase_return_items i
      JOIN purchase_returns r ON r.id = i.purchase_return_id
      WHERE r.purchase_id = :purchaseId AND r.status = 'posted'
      GROUP BY i.purchase_item_id
      ''',
      variables: <Variable<int>>[Variable<int>(purchaseId)],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.purchaseReturnItems,
        _db.purchaseReturns,
      },
    ).get();
    return <int, int>{
      for (final row in rows)
        row.read<int>('purchase_item_id'): row.read<int>('returned_scaled'),
    };
  }

  Expression<bool> _buildWhere(PurchaseFilter filter) {
    Expression<bool> predicate = _db.purchases.id.isBiggerThanValue(0);

    if (!filter.includeVoided) {
      predicate = predicate &
          _db.purchases.status.equals(DocumentStatus.posted.wireValue);
    }
    if (filter.supplierId != null) {
      predicate = predicate & _db.purchases.supplierId.equals(filter.supplierId!);
    }
    if (filter.currencyId != null) {
      predicate = predicate & _db.purchases.currencyId.equals(filter.currencyId!);
    }
    if (filter.from != null) {
      predicate = predicate &
          _db.purchases.createdAt
              .isBiggerOrEqualValue(toStorageTimestamp(filter.from!));
    }
    if (filter.to != null) {
      predicate = predicate &
          _db.purchases.createdAt
              .isSmallerOrEqualValue(toStorageTimestamp(filter.to!));
    }
    if (filter.onlyUnpaid) {
      predicate = predicate &
          _db.purchases.paidAmount.isSmallerThan(_db.purchases.total);
    }
    final term = filter.searchTerm?.trim();
    if (term != null && term.isNotEmpty) {
      predicate =
          predicate & _db.purchases.invoiceNo.like('%$term%', escapeChar: r'\');
    }
    return predicate;
  }

  Future<Map<int, String>> _supplierNames(Iterable<int> ids) async {
    final list = ids.toSet().toList(growable: false);
    if (list.isEmpty) return const <int, String>{};
    final rows =
        await (_db.select(_db.suppliers)..where((t) => t.id.isIn(list))).get();
    return <int, String>{for (final row in rows) row.id: row.name};
  }

  Future<Purchase> _hydrate(PurchaseRow row) async {
    final itemRows = await (_db.select(_db.purchaseItems)
          ..where((t) => t.purchaseId.equals(row.id))
          ..orderBy(<OrderClauseGenerator<$PurchaseItemsTable>>[
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
    final paymentRows = await (_db.select(_db.purchasePayments)
          ..where((t) => t.purchaseId.equals(row.id))
          ..orderBy(<OrderClauseGenerator<$PurchasePaymentsTable>>[
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
    final currency = await (_db.select(_db.currencies)
          ..where((t) => t.id.equals(row.currencyId)))
        .getSingleOrNull();
    final names = await _supplierNames(
      <int>[if (row.supplierId != null) row.supplierId!],
    );

    return _fromRow(
      row,
      supplierName: names[row.supplierId],
      currencyCode: currency?.code,
      currencyDecimalDigits: currency?.decimalDigits ?? 2,
      lines: <PurchaseLine>[
        for (final item in itemRows)
          PurchaseLine(
            id: item.id,
            productId: item.productId,
            productName: item.productNameSnapshot,
            quantityScaled: item.quantityScaled,
            unitCostMinor: item.unitCost,
            lineDiscountMinor: item.lineDiscount,
          ),
      ],
      payments: <PurchasePayment>[
        for (final payment in paymentRows)
          PurchasePayment(
            id: payment.id,
            paymentMethod: PaymentMethod.fromWire(payment.paymentMethod),
            currencyId: payment.currencyId,
            amountMinor: payment.amount,
            exchangeRateNumerator: payment.exchangeRateNumerator,
            exchangeRateDenominator: payment.exchangeRateDenominator,
            baseAmountMinor: payment.baseAmount,
            cashSessionId: payment.cashSessionId,
            notes: payment.notes,
          ),
      ],
    );
  }

  Purchase _fromRow(
    PurchaseRow row, {
    String? supplierName,
    String? currencyCode,
    int currencyDecimalDigits = 2,
    List<PurchaseLine> lines = const <PurchaseLine>[],
    List<PurchasePayment> payments = const <PurchasePayment>[],
  }) {
    return Purchase(
      id: row.id,
      invoiceNo: row.invoiceNo,
      supplierId: row.supplierId,
      supplierName: supplierName,
      currencyId: row.currencyId,
      currencyCode: currencyCode,
      currencyDecimalDigits: currencyDecimalDigits,
      exchangeRateNumerator: row.exchangeRateNumerator,
      exchangeRateDenominator: row.exchangeRateDenominator,
      subtotalMinor: row.subtotal,
      discountMinor: row.discount,
      additionalCostMinor: row.additionalCost,
      totalMinor: row.total,
      paidAmountMinor: row.paidAmount,
      baseTotalMinor: row.baseTotal,
      basePaidAmountMinor: row.basePaidAmount,
      status: DocumentStatus.fromWire(row.status),
      cashSessionId: row.cashSessionId,
      userId: row.userId,
      supplierReference: row.supplierReference,
      notes: row.notes,
      createdAtStorage: row.createdAt,
      updatedAtStorage: row.updatedAt,
      lines: lines,
      payments: payments,
    );
  }
}

/// Filters for the purchase list.
class PurchaseFilter {
  const PurchaseFilter({
    this.searchTerm,
    this.supplierId,
    this.currencyId,
    this.from,
    this.to,
    this.onlyUnpaid = false,
    this.includeVoided = false,
  });

  final String? searchTerm;
  final int? supplierId;
  final int? currencyId;
  final DateTime? from;
  final DateTime? to;
  final bool onlyUnpaid;
  final bool includeVoided;
}
