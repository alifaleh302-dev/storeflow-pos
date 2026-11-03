import 'package:drift/drift.dart';

import '../../../../core/constants/enums.dart';
import '../../../../core/database/audit_service.dart';
import '../../../../core/database/sequence_service.dart';
import '../../../../core/database/settings_service.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/utils/pagination.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../infrastructure/database/app_database.dart';
import '../../../inventory/data/inventory_service.dart';
import '../../domain/entities/sale.dart';
import '../../domain/services/sale_calculator.dart';

/// What happened to a checkout attempt.
enum SalePostOutcome {
  /// A new invoice was created.
  created,

  /// The idempotency key had already been used. The original invoice is returned
  /// unchanged and nothing new was written.
  replayed,
}

/// The result of posting a sale.
class SalePostResult {
  const SalePostResult({
    required this.outcome,
    required this.saleId,
    required this.invoiceNo,
  });

  final SalePostOutcome outcome;
  final int saleId;
  final String invoiceNo;

  bool get wasReplay => outcome == SalePostOutcome.replayed;
}

/// Reads and writes sale invoices.
///
/// The whole checkout — invoice, lines, tenders, stock movements, stock balances,
/// the customer's account and the audit entry — is written inside a single
/// transaction. A failure anywhere rolls back all of it, so an invoice can never
/// exist without the stock and payment records that justify it.
class SaleRepository {
  SaleRepository(
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

  /// Posts a sale.
  ///
  /// [idempotencyKey] guards against a double submit from a slow device or an
  /// impatient double tap: a second call with the same key returns the original
  /// invoice instead of charging the customer twice.
  ///
  /// [cashSessionId] is optional. When given, only the cash portion of the
  /// payment produces a drawer movement; a transfer or a credit sale never
  /// touches the till.
  Future<SalePostResult> post({
    required SaleDraft draft,
    required List<PaymentAllocation> payments,
    String? idempotencyKey,
    int? cashSessionId,
    int? userId,
  }) async {
    if (draft.isEmpty) {
      throw const ValidationFailure('The cart is empty', field: 'cart');
    }

    // Checked before the transaction, so a replayed request never opens one.
    if (idempotencyKey != null) {
      final existing = await (_db.select(_db.idempotencyKeys)
            ..where((t) => t.key.equals(idempotencyKey)))
          .getSingleOrNull();
      if (existing != null) {
        final saleId = existing.resultId;
        if (saleId == null) {
          throw const ValidationFailure(
            'This operation is already in progress',
            field: 'idempotencyKey',
          );
        }
        final sale = await findById(saleId);
        return SalePostResult(
          outcome: SalePostOutcome.replayed,
          saleId: saleId,
          invoiceNo: sale?.invoiceNo ?? '',
        );
      }
    }

    final allowNegativeStock = await _settings.allowNegativeStock();

    return _db.transaction(() async {
      // Stock is re-read inside the transaction: between the cashier adding an
      // item and confirming, another checkout may have consumed it.
      final positions = await _inventory.positionsOf(
        draft.lines.map((line) => line.productId),
      );
      final available = <int, int>{
        for (final line in draft.lines)
          line.productId: positions[line.productId]?.quantityScaled ?? 0,
      };

      final validation = SaleCalculator.validate(
        draft: draft,
        availableByProduct: available,
        allowNegativeStock: allowNegativeStock,
      );
      if (validation.errors.contains('empty_cart')) {
        throw const ValidationFailure('The cart is empty', field: 'cart');
      }
      if (validation.errors.isNotEmpty) {
        throw ValidationFailure(
          'The sale is not valid',
          field: 'cart',
          details: <String, Object?>{'errors': validation.errors},
        );
      }
      if (validation.shortages.isNotEmpty) {
        final first = validation.shortages.first;
        throw InsufficientStockFailure(
          productName: first.productName,
          availableScaled: first.availableScaled,
          requestedScaled: first.requestedScaled,
        );
      }

      SaleCalculator.assertSettles(
        baseTotalMinor: draft.baseTotalMinor,
        allocations: payments,
      );

      final timestamp = nowStorageTimestamp();
      final invoiceNo = await _sequences.next('sale');

      // Totals are recomputed here from the lines rather than trusted from the
      // caller, so a stale or manipulated UI state cannot set the amount.
      final subtotal = draft.subtotalMinor;
      final lineDiscountTotal = draft.lineDiscountTotalMinor;
      final total = draft.totalMinor;
      final baseSubtotal = SaleCalculator.toBaseMinor(
        amountMinor: subtotal,
        rateNumerator: draft.exchangeRateNumerator,
        rateDenominator: draft.exchangeRateDenominator,
      );
      final baseTotal = draft.baseTotalMinor;
      final costTotal = draft.costTotalMinor;
      // Only money actually received counts as paid. A credit tender closes the
      // invoice but becomes debt, so including it here would overstate both the
      // collected revenue and the customer's balance.
      final basePaid = payments
          .where((p) => !p.paymentMethod.isCredit)
          .fold<int>(0, (sum, p) => sum + p.baseAmountMinor);
      // The invoice currency may differ from the base currency, so the money
      // portion is converted back from base with this invoice's own rate rather
      // than summed across currencies.
      final paid = SaleCalculator.fromBaseMinor(
        baseMinor: basePaid,
        rateNumerator: draft.exchangeRateNumerator,
        rateDenominator: draft.exchangeRateDenominator,
      );

      final saleId = await _db.into(_db.sales).insert(
            SalesCompanion.insert(
              invoiceNo: invoiceNo,
              customerId: Value(draft.customerId),
              currencyId: draft.currencyId,
              exchangeRateNumerator: Value(draft.exchangeRateNumerator),
              exchangeRateDenominator: Value(draft.exchangeRateDenominator),
              subtotal: Value(subtotal),
              lineDiscountTotal: Value(lineDiscountTotal),
              invoiceDiscount: Value(draft.invoiceDiscountMinor),
              total: Value(total),
              paidAmount: Value(paid),
              costTotal: Value(costTotal),
              profit: Value(baseTotal - costTotal),
              baseSubtotal: Value(baseSubtotal),
              baseTotal: Value(baseTotal),
              basePaidAmount: Value(basePaid),
              baseCostTotal: Value(costTotal),
              status: DocumentStatus.posted.wireValue,
              cashSessionId: Value(cashSessionId),
              userId: Value(userId),
              notes: Value(draft.notes),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );

      for (final line in draft.lines) {
        await _db.into(_db.saleItems).insert(
              SaleItemsCompanion.insert(
                saleId: saleId,
                productId: line.productId,
                productNameSnapshot: line.productName,
                skuSnapshot: Value(line.sku),
                quantityScaled: line.quantityScaled,
                unitPrice: line.unitPriceMinor,
                unitCost: line.unitCostMinor,
                lineDiscount: Value(line.lineDiscountMinor),
                total: line.netMinor,
                costTotal: Value(line.costMinor),
              ),
            );

        await _inventory.apply(
          productId: line.productId,
          movementType: MovementType.sale,
          signedQuantityScaled: -line.quantityScaled,
          referenceType: ReferenceType.sale,
          referenceId: saleId,
          allowNegativeStock: allowNegativeStock,
        );
      }

      for (final payment in payments) {
        await _db.into(_db.salePayments).insert(
              SalePaymentsCompanion.insert(
                saleId: saleId,
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

        // Only cash moves the physical drawer. A transfer or a card payment is
        // money the store has, but not money in the till.
        if (payment.paymentMethod.isCash &&
            cashSessionId != null &&
            payment.amountMinor > 0) {
          await _db.into(_db.cashTransactions).insert(
                CashTransactionsCompanion.insert(
                  sessionId: cashSessionId,
                  transactionType: CashTransactionType.saleReceipt.wireValue,
                  amountBase: payment.baseAmountMinor,
                  currencyId: payment.currencyId,
                  originalAmount: payment.amountMinor,
                  exchangeRateNumerator: Value(payment.exchangeRateNumerator),
                  exchangeRateDenominator:
                      Value(payment.exchangeRateDenominator),
                  referenceType: Value(ReferenceType.sale.wireValue),
                  referenceId: Value(saleId),
                  description: Value('Sale $invoiceNo'),
                  createdAt: timestamp,
                ),
              );
        }
      }

      // The unpaid remainder becomes the customer's debt. An unpaid sale with no
      // customer is rejected, because there is nobody to owe it.
      final unpaidBase = baseTotal - basePaid;
      if (unpaidBase > 0) {
        if (draft.customerId == null) {
          throw const ValidationFailure(
            'An unpaid balance needs a customer',
            field: 'customerId',
          );
        }
        await _db.into(_db.customerAccountEntries).insert(
              CustomerAccountEntriesCompanion.insert(
                customerId: draft.customerId!,
                direction: LedgerDirection.debit.wireValue,
                amountMinor: unpaidBase,
                currencyId: draft.currencyId,
                exchangeRateNumerator: Value(draft.exchangeRateNumerator),
                exchangeRateDenominator: Value(draft.exchangeRateDenominator),
                referenceType: ReferenceType.sale.wireValue,
                referenceId: Value(saleId),
                description: Value('Credit sale $invoiceNo'),
                createdAt: timestamp,
              ),
            );
      }

      if (idempotencyKey != null) {
        await _db.into(_db.idempotencyKeys).insert(
              IdempotencyKeysCompanion.insert(
                key: idempotencyKey,
                operation: 'sale.post',
                resultId: Value(saleId),
                createdAt: timestamp,
              ),
            );
      }

      await _audit.log(
        action: 'sale.posted',
        entityType: 'sale',
        entityId: saleId,
        description: 'Sale $invoiceNo posted',
        payload: <String, Object?>{
          'invoiceNo': invoiceNo,
          'totalMinor': total,
          'baseTotalMinor': baseTotal,
          'currencyId': draft.currencyId,
          'lineCount': draft.lines.length,
          'paidMinor': paid,
        },
        userId: userId,
      );

      return SalePostResult(
        outcome: SalePostOutcome.created,
        saleId: saleId,
        invoiceNo: invoiceNo,
      );
    });
  }

  /// Loads a full invoice, with its lines and tenders.
  Future<Sale?> findById(int id) async {
    final row = await (_db.select(_db.sales)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return _hydrate(row);
  }

  /// Loads an invoice by its printed number, for a reprint.
  Future<Sale?> findByInvoiceNo(String invoiceNo) async {
    final row = await (_db.select(_db.sales)
          ..where((t) => t.invoiceNo.equals(invoiceNo.trim())))
        .getSingleOrNull();
    if (row == null) return null;
    return _hydrate(row);
  }

  /// One page of invoices, newest first.
  Future<Page<Sale>> search({
    SaleFilter filter = const SaleFilter(),
    PageRequest request = const PageRequest(),
  }) async {
    final rows = await (_db.select(_db.sales)
          ..where((t) => _buildWhere(filter))
          ..orderBy(<OrderClauseGenerator<$SalesTable>>[
            (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.desc),
          ])
          ..limit(request.effectiveLimit, offset: request.offset))
        .get();

    final countQuery = _db.selectOnly(_db.sales)
      ..addColumns(<Expression<Object>>[countAll()])
      ..where(_buildWhere(filter));
    final total = (await countQuery.getSingle()).read(countAll()) ?? 0;

    final names = await _customerNames(
      rows.map((row) => row.customerId).whereType<int>(),
    );

    return Page<Sale>(
      items: <Sale>[
        for (final row in rows)
          _fromRow(row, customerName: names[row.customerId]),
      ],
      totalCount: total,
      request: request,
    );
  }

  /// The most recent invoices, for the dashboard and a quick reprint.
  Future<List<Sale>> recent({int limit = 10}) async {
    final page = await search(request: PageRequest(limit: limit));
    return page.items;
  }

  /// Voids a posted invoice and reverses its effects.
  ///
  /// A posted invoice is never deleted. Voiding restores the stock, reverses the
  /// customer's debt and marks the invoice void, so the original document stays
  /// visible in the history with its lines and tenders intact.
  Future<void> voidSale({
    required int saleId,
    required String reason,
    int? userId,
  }) async {
    final sale = await findById(saleId);
    if (sale == null) {
      throw NotFoundFailure(
        'Sale not found',
        details: <String, Object?>{'saleId': saleId},
      );
    }
    if (sale.isVoided) {
      throw const ValidationFailure(
        'This invoice is already void',
        field: 'status',
      );
    }

    final allowNegativeStock = await _settings.allowNegativeStock();

    await _db.transaction(() async {
      final timestamp = nowStorageTimestamp();

      for (final line in sale.lines) {
        await _inventory.apply(
          productId: line.productId,
          movementType: MovementType.customerReturn,
          signedQuantityScaled: line.quantityScaled,
          referenceType: ReferenceType.salesReturn,
          referenceId: saleId,
          allowNegativeStock: allowNegativeStock,
          unitCost: line.unitCostMinor,
          notes: 'Void of ${sale.invoiceNo}',
        );
      }

      if (sale.customerId != null && sale.baseOutstandingMinor > 0) {
        await _db.into(_db.customerAccountEntries).insert(
              CustomerAccountEntriesCompanion.insert(
                customerId: sale.customerId!,
                direction: LedgerDirection.credit.wireValue,
                amountMinor: sale.baseOutstandingMinor,
                currencyId: sale.currencyId,
                exchangeRateNumerator: Value(sale.exchangeRateNumerator),
                exchangeRateDenominator: Value(sale.exchangeRateDenominator),
                referenceType: ReferenceType.sale.wireValue,
                referenceId: Value(saleId),
                description: Value('Void of ${sale.invoiceNo}'),
                createdAt: timestamp,
              ),
            );
      }

      await (_db.update(_db.sales)..where((t) => t.id.equals(saleId))).write(
        SalesCompanion(
          status: Value(DocumentStatus.voided.wireValue),
          notes: Value(
            sale.notes == null ? reason : '${sale.notes}\nVoid: $reason',
          ),
          updatedAt: Value(timestamp),
        ),
      );

      await _audit.log(
        action: 'sale.voided',
        entityType: 'sale',
        entityId: saleId,
        description: 'Sale ${sale.invoiceNo} voided',
        payload: <String, Object?>{'reason': reason},
        userId: userId,
      );
    });
  }

  /// Registers a customer return against a posted sale.
  ///
  /// [quantityBySaleItem] maps a sale item id to the scaled quantity coming back.
  /// A return is capped at what was sold minus what has already come back, so a
  /// customer cannot return more than they bought.
  Future<String> createReturn({
    required int saleId,
    required Map<int, int> quantityBySaleItem,
    required bool refundCash,
    String? reason,
    int? cashSessionId,
    int? userId,
  }) async {
    final sale = await findById(saleId);
    if (sale == null) {
      throw NotFoundFailure(
        'Sale not found',
        details: <String, Object?>{'saleId': saleId},
      );
    }
    if (sale.isVoided) {
      throw const ValidationFailure(
        'A voided invoice cannot be returned',
        field: 'status',
      );
    }
    if (quantityBySaleItem.isEmpty) {
      throw const ValidationFailure(
        'A return needs at least one line',
        field: 'lines',
      );
    }

    final allowNegativeStock = await _settings.allowNegativeStock();
    final alreadyReturned = await _returnedQuantities(saleId);

    final lines = <SaleLine>[];
    for (final entry in quantityBySaleItem.entries) {
      final quantity = entry.value;
      if (quantity <= 0) {
        throw const ValidationFailure(
          'Return quantities must be positive',
          field: 'quantity',
        );
      }
      final item = sale.lines.firstWhere(
        (line) => line.id == entry.key,
        orElse: () => throw ValidationFailure(
          'Sale line not found on this invoice',
          field: 'lines',
          details: <String, Object?>{'saleItemId': entry.key},
        ),
      );
      final returned = alreadyReturned[entry.key] ?? 0;
      final returnable = item.quantityScaled - returned;
      if (quantity > returnable) {
        throw ValidationFailure(
          'Cannot return more than was sold for "${item.productName}"',
          field: 'quantity',
          details: <String, Object?>{
            'saleItemId': entry.key,
            'soldScaled': item.quantityScaled,
            'alreadyReturnedScaled': returned,
            'requestedScaled': quantity,
          },
        );
      }
      lines.add(item.copyWith(quantityScaled: quantity));
    }

    return _db.transaction(() async {
      final timestamp = nowStorageTimestamp();
      final returnNo = await _sequences.next('sales_return');
      final total = lines.fold<int>(0, (sum, line) => sum + line.netMinor);
      final costTotal = lines.fold<int>(0, (sum, line) => sum + line.costMinor);

      final returnId = await _db.into(_db.salesReturns).insert(
            SalesReturnsCompanion.insert(
              returnNo: returnNo,
              saleId: saleId,
              customerId: Value(sale.customerId),
              currencyId: sale.currencyId,
              exchangeRateNumerator: Value(sale.exchangeRateNumerator),
              exchangeRateDenominator: Value(sale.exchangeRateDenominator),
              total: total,
              costTotal: Value(costTotal),
              settlement: refundCash ? 'refund' : 'credit',
              status: DocumentStatus.posted.wireValue,
              reason: Value(reason),
              cashSessionId: Value(cashSessionId),
              createdAt: timestamp,
            ),
          );

      for (final line in lines) {
        await _db.into(_db.salesReturnItems).insert(
              SalesReturnItemsCompanion.insert(
                salesReturnId: returnId,
                saleItemId: line.id!,
                productId: line.productId,
                quantityScaled: line.quantityScaled,
                unitPrice: line.unitPriceMinor,
                unitCost: line.unitCostMinor,
                total: line.netMinor,
              ),
            );

        await _inventory.apply(
          productId: line.productId,
          movementType: MovementType.customerReturn,
          signedQuantityScaled: line.quantityScaled,
          referenceType: ReferenceType.salesReturn,
          referenceId: returnId,
          allowNegativeStock: allowNegativeStock,
          unitCost: line.unitCostMinor,
          notes: reason,
        );
      }

      final baseTotal = SaleCalculator.toBaseMinor(
        amountMinor: total,
        rateNumerator: sale.exchangeRateNumerator,
        rateDenominator: sale.exchangeRateDenominator,
      );

      if (refundCash) {
        if (cashSessionId == null) {
          throw const ValidationFailure(
            'A cash refund needs an open cash session',
            field: 'cashSessionId',
          );
        }
        await _db.into(_db.cashTransactions).insert(
              CashTransactionsCompanion.insert(
                sessionId: cashSessionId,
                transactionType: CashTransactionType.adjustment.wireValue,
                amountBase: -baseTotal,
                currencyId: sale.currencyId,
                originalAmount: total,
                exchangeRateNumerator: Value(sale.exchangeRateNumerator),
                exchangeRateDenominator: Value(sale.exchangeRateDenominator),
                referenceType: Value(ReferenceType.salesReturn.wireValue),
                referenceId: Value(returnId),
                description: Value('Refund for $returnNo'),
                createdAt: timestamp,
              ),
            );
      } else if (sale.customerId != null) {
        await _db.into(_db.customerAccountEntries).insert(
              CustomerAccountEntriesCompanion.insert(
                customerId: sale.customerId!,
                direction: LedgerDirection.credit.wireValue,
                amountMinor: baseTotal,
                currencyId: sale.currencyId,
                exchangeRateNumerator: Value(sale.exchangeRateNumerator),
                exchangeRateDenominator: Value(sale.exchangeRateDenominator),
                referenceType: ReferenceType.salesReturn.wireValue,
                referenceId: Value(returnId),
                description: Value('Return $returnNo'),
                createdAt: timestamp,
              ),
            );
      } else {
        throw const ValidationFailure(
          'A credit return needs a customer',
          field: 'customerId',
        );
      }

      await _audit.log(
        action: 'sale.returned',
        entityType: 'sales_return',
        entityId: returnId,
        description: 'Return $returnNo against ${sale.invoiceNo}',
        payload: <String, Object?>{
          'saleId': saleId,
          'returnNo': returnNo,
          'totalMinor': total,
          'settlement': refundCash ? 'refund' : 'credit',
        },
        userId: userId,
      );

      return returnNo;
    });
  }

  /// How much of each sale line has already been returned.
  Future<Map<int, int>> _returnedQuantities(int saleId) async {
    final rows = await _db.customSelect(
      '''
      SELECT i.sale_item_id AS sale_item_id,
             SUM(i.quantity_scaled) AS returned_scaled
      FROM sales_return_items i
      JOIN sales_returns r ON r.id = i.sales_return_id
      WHERE r.sale_id = :saleId AND r.status = 'posted'
      GROUP BY i.sale_item_id
      ''',
      variables: <Variable<int>>[Variable<int>(saleId)],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.salesReturnItems,
        _db.salesReturns,
      },
    ).get();
    return <int, int>{
      for (final row in rows)
        row.read<int>('sale_item_id'): row.read<int>('returned_scaled'),
    };
  }

  Expression<bool> _buildWhere(SaleFilter filter) {
    Expression<bool> predicate = _db.sales.id.isBiggerThanValue(0);

    if (!filter.includeVoided) {
      predicate =
          predicate & _db.sales.status.equals(DocumentStatus.posted.wireValue);
    }
    if (filter.customerId != null) {
      predicate = predicate & _db.sales.customerId.equals(filter.customerId!);
    }
    if (filter.currencyId != null) {
      predicate = predicate & _db.sales.currencyId.equals(filter.currencyId!);
    }
    if (filter.from != null) {
      predicate = predicate &
          _db.sales.createdAt
              .isBiggerOrEqualValue(toStorageTimestamp(filter.from!));
    }
    if (filter.to != null) {
      predicate = predicate &
          _db.sales.createdAt
              .isSmallerOrEqualValue(toStorageTimestamp(filter.to!));
    }
    if (filter.onlyUnpaid) {
      predicate =
          predicate & _db.sales.paidAmount.isSmallerThan(_db.sales.total);
    }
    final term = filter.searchTerm?.trim();
    if (term != null && term.isNotEmpty) {
      predicate =
          predicate & _db.sales.invoiceNo.like('%$term%', escapeChar: r'\');
    }
    return predicate;
  }

  Future<Map<int, String>> _customerNames(Iterable<int> ids) async {
    final list = ids.toSet().toList(growable: false);
    if (list.isEmpty) return const <int, String>{};
    final rows =
        await (_db.select(_db.customers)..where((t) => t.id.isIn(list))).get();
    return <int, String>{for (final row in rows) row.id: row.name};
  }

  Future<Sale> _hydrate(SaleRow row) async {
    final itemRows = await (_db.select(_db.saleItems)
          ..where((t) => t.saleId.equals(row.id))
          ..orderBy(<OrderClauseGenerator<$SaleItemsTable>>[
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
    final paymentRows = await (_db.select(_db.salePayments)
          ..where((t) => t.saleId.equals(row.id))
          ..orderBy(<OrderClauseGenerator<$SalePaymentsTable>>[
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
    final currency = await (_db.select(_db.currencies)
          ..where((t) => t.id.equals(row.currencyId)))
        .getSingleOrNull();
    final names = await _customerNames(
      <int>[if (row.customerId != null) row.customerId!],
    );

    return _fromRow(
      row,
      customerName: names[row.customerId],
      currencyCode: currency?.code,
      currencySymbol: currency?.symbol,
      currencyDecimalDigits: currency?.decimalDigits ?? 2,
      lines: <SaleLine>[
        for (final item in itemRows)
          SaleLine(
            id: item.id,
            productId: item.productId,
            productName: item.productNameSnapshot,
            sku: item.skuSnapshot,
            quantityScaled: item.quantityScaled,
            unitPriceMinor: item.unitPrice,
            unitCostMinor: item.unitCost,
            lineDiscountMinor: item.lineDiscount,
          ),
      ],
      payments: <SalePayment>[
        for (final payment in paymentRows)
          SalePayment(
            id: payment.id,
            paymentMethod: PaymentMethod.fromWire(payment.paymentMethod),
            currencyId: payment.currencyId,
            amountMinor: payment.amount,
            exchangeRateNumerator: payment.exchangeRateNumerator,
            exchangeRateDenominator: payment.exchangeRateDenominator,
            baseAmountMinor: payment.baseAmount,
            cashSessionId: payment.cashSessionId,
            notes: payment.notes,
            createdAtStorage: payment.createdAt,
          ),
      ],
    );
  }

  Sale _fromRow(
    SaleRow row, {
    String? customerName,
    String? currencyCode,
    String? currencySymbol,
    int currencyDecimalDigits = 2,
    List<SaleLine> lines = const <SaleLine>[],
    List<SalePayment> payments = const <SalePayment>[],
  }) {
    return Sale(
      id: row.id,
      invoiceNo: row.invoiceNo,
      customerId: row.customerId,
      customerName: customerName,
      currencyId: row.currencyId,
      currencyCode: currencyCode,
      currencySymbol: currencySymbol,
      currencyDecimalDigits: currencyDecimalDigits,
      exchangeRateNumerator: row.exchangeRateNumerator,
      exchangeRateDenominator: row.exchangeRateDenominator,
      subtotalMinor: row.subtotal,
      lineDiscountTotalMinor: row.lineDiscountTotal,
      invoiceDiscountMinor: row.invoiceDiscount,
      totalMinor: row.total,
      paidAmountMinor: row.paidAmount,
      costTotalMinor: row.costTotal,
      baseSubtotalMinor: row.baseSubtotal,
      baseTotalMinor: row.baseTotal,
      basePaidAmountMinor: row.basePaidAmount,
      baseCostTotalMinor: row.baseCostTotal,
      status: DocumentStatus.fromWire(row.status),
      cashSessionId: row.cashSessionId,
      userId: row.userId,
      notes: row.notes,
      createdAtStorage: row.createdAt,
      updatedAtStorage: row.updatedAt,
      lines: lines,
      payments: payments,
    );
  }
}

/// Filters for the invoice list.
class SaleFilter {
  const SaleFilter({
    this.searchTerm,
    this.customerId,
    this.currencyId,
    this.from,
    this.to,
    this.onlyUnpaid = false,
    this.includeVoided = false,
  });

  final String? searchTerm;
  final int? customerId;
  final int? currencyId;
  final DateTime? from;
  final DateTime? to;
  final bool onlyUnpaid;
  final bool includeVoided;
}
