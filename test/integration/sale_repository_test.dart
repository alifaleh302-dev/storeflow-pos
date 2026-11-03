import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/constants/enums.dart';
import 'package:storeflow_pos/core/errors/failures.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/core/utils/pagination.dart';
import 'package:storeflow_pos/features/inventory/data/inventory_service.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/features/sales/data/repositories/sale_repository.dart';
import 'package:storeflow_pos/features/sales/domain/entities/sale.dart';
import 'package:storeflow_pos/features/sales/domain/services/sale_calculator.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

void main() {
  late AppDatabase db;
  late InventoryService inventory;
  late ProductRepository products;
  late SaleRepository sales;

  const scale = Quantity.scale;
  late int currencyId;
  late int customerId;

  setUp(() async {
    db = AppDatabase.memory();
    inventory = InventoryService(db);
    products = ProductRepository(db);
    sales = SaleRepository(db);

    // The database seeds SAR as the base currency; reuse it rather than
    // inserting a second base currency.
    final base = await (db.select(db.currencies)
          ..where((t) => t.isBase.equals(true)))
        .getSingle();
    currencyId = base.id;
    customerId = await db.into(db.customers).insert(
          CustomersCompanion.insert(
            name: 'Walk-in Customer',
            createdAt: '2026-01-01T00:00:00.000Z',
            updatedAt: '2026-01-01T00:00:00.000Z',
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  /// Creates a product and stocks it at [cost] per unit.
  Future<int> stockedProduct({
    required String name,
    required int unitsOnHand,
    int cost = 10000,
    int price = 15000,
    String? sku,
  }) async {
    final id = await products.create(
      name: name,
      sku: sku,
      purchaseCostMinor: cost,
      sellingPriceMinor: price,
    );
    await inventory.apply(
      productId: id,
      movementType: MovementType.purchase,
      signedQuantityScaled: unitsOnHand * scale,
      referenceType: ReferenceType.purchase,
      allowNegativeStock: false,
      unitCost: cost,
    );
    return id;
  }

  SaleDraft draftFor(
    List<SaleLine> lines, {
    int? customer,
    int invoiceDiscount = 0,
  }) {
    return SaleDraft(
      currencyId: currencyId,
      currencyDecimalDigits: 2,
      customerId: customer,
      lines: lines,
      invoiceDiscountMinor: invoiceDiscount,
    );
  }

  PaymentAllocation cashFor(int amountMinor) => PaymentAllocation(
        paymentMethod: PaymentMethod.cash,
        currencyId: currencyId,
        amountMinor: amountMinor,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
        baseAmountMinor: amountMinor,
      );

  group('SaleDraft arithmetic', () {
    test('extends a line and totals the cart', () {
      final draft = draftFor(<SaleLine>[
        const SaleLine(
          productId: 1,
          productName: 'A',
          quantityScaled: 3 * scale,
          unitPriceMinor: 15000,
          unitCostMinor: 10000,
        ),
        const SaleLine(
          productId: 2,
          productName: 'B',
          quantityScaled: 2 * scale,
          unitPriceMinor: 5000,
          unitCostMinor: 2000,
        ),
      ]);

      expect(draft.subtotalMinor, 3 * 15000 + 2 * 5000);
      expect(draft.costTotalMinor, 3 * 10000 + 2 * 2000);
      expect(draft.totalMinor, draft.subtotalMinor);
    });

    test('subtracts an invoice discount from the total', () {
      final draft = draftFor(
        <SaleLine>[
          const SaleLine(
            productId: 1,
            productName: 'A',
            quantityScaled: 2 * scale,
            unitPriceMinor: 10000,
            unitCostMinor: 6000,
          ),
        ],
        invoiceDiscount: 500,
      );
      expect(draft.subtotalMinor, 20000);
      expect(draft.totalMinor, 19500);
    });

    test('merges a repeated product instead of adding a second line', () {
      var draft = draftFor(<SaleLine>[
        const SaleLine(
          productId: 1,
          productName: 'A',
          quantityScaled: scale,
          unitPriceMinor: 10000,
          unitCostMinor: 6000,
        ),
      ]);
      draft = draft.addLine(
        const SaleLine(
          productId: 1,
          productName: 'A',
          quantityScaled: 2 * scale,
          unitPriceMinor: 10000,
          unitCostMinor: 6000,
        ),
      );
      expect(draft.lines, hasLength(1));
      expect(draft.lines.single.quantityScaled, 3 * scale);
    });

    test('removes a line when its quantity reaches zero', () {
      var draft = draftFor(<SaleLine>[
        const SaleLine(
          productId: 1,
          productName: 'A',
          quantityScaled: scale,
          unitPriceMinor: 10000,
          unitCostMinor: 6000,
        ),
      ]);
      draft = draft.setQuantity(1, 0);
      expect(draft.isEmpty, isTrue);
    });

    test('never lets a line discount drive the line negative', () {
      const line = SaleLine(
        productId: 1,
        productName: 'A',
        quantityScaled: scale,
        unitPriceMinor: 10000,
        unitCostMinor: 6000,
        lineDiscountMinor: 99999,
      );
      expect(line.netMinor, 0);
    });

    test('computes a fractional-quantity line exactly', () {
      const line = SaleLine(
        productId: 1,
        productName: 'Sugar',
        quantityScaled: 1500,
        unitPriceMinor: 4000,
        unitCostMinor: 2500,
      );
      expect(line.netMinor, 6000);
      expect(line.costMinor, 3750);
      expect(line.grossProfitMinor, 2250);
    });
  });

  group('SaleCalculator', () {
    test('flags an empty cart', () {
      final result = SaleCalculator.validate(
        draft: draftFor(const <SaleLine>[]),
        availableByProduct: const <int, int>{},
        allowNegativeStock: false,
      );
      expect(result.isValid, isFalse);
      expect(result.errors, contains('empty_cart'));
    });

    test('reports a shortage with the missing quantity', () {
      final result = SaleCalculator.validate(
        draft: draftFor(<SaleLine>[
          const SaleLine(
            productId: 1,
            productName: 'A',
            quantityScaled: 5 * scale,
            unitPriceMinor: 100,
            unitCostMinor: 50,
          ),
        ]),
        availableByProduct: const <int, int>{1: 3 * scale},
        allowNegativeStock: false,
      );
      expect(result.isValid, isFalse);
      expect(result.shortages.single.missingScaled, 2 * scale);
    });

    test('ignores shortages when negative stock is allowed', () {
      final result = SaleCalculator.validate(
        draft: draftFor(<SaleLine>[
          const SaleLine(
            productId: 1,
            productName: 'A',
            quantityScaled: 5 * scale,
            unitPriceMinor: 100,
            unitCostMinor: 50,
          ),
        ]),
        availableByProduct: const <int, int>{1: 0},
        allowNegativeStock: true,
      );
      expect(result.isValid, isTrue);
    });

    test('rejects a discount larger than the subtotal', () {
      final result = SaleCalculator.validate(
        draft: draftFor(
          <SaleLine>[
            const SaleLine(
              productId: 1,
              productName: 'A',
              quantityScaled: scale,
              unitPriceMinor: 1000,
              unitCostMinor: 500,
            ),
          ],
          invoiceDiscount: 5000,
        ),
        availableByProduct: const <int, int>{1: scale},
        allowNegativeStock: false,
      );
      expect(result.errors, contains('discount_exceeds_subtotal'));
    });

    test('rejects an overpayment', () {
      expect(
        () => SaleCalculator.assertSettles(
          baseTotalMinor: 1000,
          allocations: <PaymentAllocation>[
            PaymentAllocation(
              paymentMethod: PaymentMethod.cash,
              currencyId: 1,
              amountMinor: 1500,
              exchangeRateNumerator: 1,
              exchangeRateDenominator: 1,
              baseAmountMinor: 1500,
            ),
          ],
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('rejects an underpayment with no credit tender', () {
      expect(
        () => SaleCalculator.assertSettles(
          baseTotalMinor: 1000,
          allocations: <PaymentAllocation>[
            PaymentAllocation(
              paymentMethod: PaymentMethod.cash,
              currencyId: 1,
              amountMinor: 400,
              exchangeRateNumerator: 1,
              exchangeRateDenominator: 1,
              baseAmountMinor: 400,
            ),
          ],
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('accepts an underpayment that carries a credit tender', () {
      SaleCalculator.assertSettles(
        baseTotalMinor: 1000,
        allocations: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: 1,
            amountMinor: 400,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 400,
          ),
          PaymentAllocation(
            paymentMethod: PaymentMethod.credit,
            currencyId: 1,
            amountMinor: 600,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 600,
          ),
        ],
      );
    });

    test('converts a tender with the rate it was given', () {
      // 100.00 of a currency worth 3.75 base each -> 375.00 base.
      expect(
        SaleCalculator.toBaseMinor(
          amountMinor: 10000,
          rateNumerator: 375,
          rateDenominator: 100,
        ),
        37500,
      );
    });

    test('allocates an invoice discount without losing a minor unit', () {
      final shares = SaleCalculator.allocateInvoiceDiscount(
        lineValues: <int>[3333, 3333, 3334],
        discountMinor: 1000,
      );
      expect(shares.fold<int>(0, (sum, value) => sum + value), 1000);
    });
  });

  group('posting a sale', () {
    test('creates the invoice, its lines and its payment', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);

      final result = await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 3 * scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(45000)],
      );

      expect(result.outcome, SalePostOutcome.created);
      expect(result.invoiceNo, 'INV-000001');

      final sale = await sales.findById(result.saleId);
      expect(sale, isNotNull);
      expect(sale!.totalMinor, 45000);
      expect(sale.paidAmountMinor, 45000);
      expect(sale.isFullyPaid, isTrue);
      expect(sale.isCredit, isFalse);
      expect(sale.status, DocumentStatus.posted);
      expect(sale.lines, hasLength(1));
      expect(sale.payments, hasLength(1));
      expect(sale.lines.single.unitCostMinor, 10000);
      expect(sale.costTotalMinor, 30000);
      expect(sale.grossProfitMinor, 15000);
    });

    test('reduces stock by the quantity sold', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);

      await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 4 * scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(60000)],
      );

      final position = await inventory.positionOf(id);
      expect(position.quantityScaled, 6 * scale);
      expect(await inventory.reconcile(), isEmpty);

      final history = await inventory.history(id);
      expect(history.items.first.movementType, MovementType.sale);
      expect(history.items.first.quantityScaled, -4 * scale);
    });

    test('records the drawer movement only for cash', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final sessionId = await db.into(db.cashSessions).insert(
            CashSessionsCompanion.insert(
              openingBalance: 0,
              currencyId: currencyId,
              status: CashSessionStatus.open.wireValue,
              openedAt: '2026-01-01T00:00:00.000Z',
            ),
          );

      await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 2 * scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.bankTransfer,
            currencyId: currencyId,
            amountMinor: 30000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 30000,
          ),
        ],
        cashSessionId: sessionId,
      );

      // A transfer is money the store has, but not money in the till.
      expect(await db.select(db.cashTransactions).get(), isEmpty);
    });

    test('records a drawer movement for a cash sale', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final sessionId = await db.into(db.cashSessions).insert(
            CashSessionsCompanion.insert(
              openingBalance: 0,
              currencyId: currencyId,
              status: CashSessionStatus.open.wireValue,
              openedAt: '2026-01-01T00:00:00.000Z',
            ),
          );

      await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 2 * scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(30000)],
        cashSessionId: sessionId,
      );

      final rows = await db.select(db.cashTransactions).get();
      expect(rows, hasLength(1));
      expect(rows.single.amountBase, 30000);
      expect(
        rows.single.transactionType,
        CashTransactionType.saleReceipt.wireValue,
      );
    });

    test('rejects a sale that exceeds available stock', () async {
      final id = await stockedProduct(name: 'Scarce', unitsOnHand: 2);

      await expectLater(
        sales.post(
          draft: draftFor(<SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Scarce',
              quantityScaled: 5 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PaymentAllocation>[cashFor(75000)],
        ),
        throwsA(isA<InsufficientStockFailure>()),
      );

      // Nothing may be written: no invoice, no movement.
      expect(await db.select(db.sales).get(), isEmpty);
      expect((await inventory.positionOf(id)).quantityScaled, 2 * scale);
      expect(await inventory.reconcile(), isEmpty);
    });

    test('rejects an empty cart', () async {
      await expectLater(
        sales.post(
          draft: draftFor(const <SaleLine>[]),
          payments: <PaymentAllocation>[cashFor(0)],
        ),
        throwsA(isA<ValidationFailure>()),
      );
      expect(await db.select(db.sales).get(), isEmpty);
    });

    test('rejects a payment that does not settle the invoice', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      await expectLater(
        sales.post(
          draft: draftFor(<SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PaymentAllocation>[cashFor(10000)],
        ),
        throwsA(isA<ValidationFailure>()),
      );
      expect(await db.select(db.sales).get(), isEmpty);
      expect((await inventory.positionOf(id)).quantityScaled, 10 * scale);
    });

    test('rolls the whole checkout back when the stock step fails', () async {
      final good = await stockedProduct(name: 'Good', unitsOnHand: 10);
      final scarce = await stockedProduct(name: 'Scarce', unitsOnHand: 1);

      await expectLater(
        sales.post(
          draft: draftFor(<SaleLine>[
            SaleLine(
              productId: good,
              productName: 'Good',
              quantityScaled: 2 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
            SaleLine(
              productId: scarce,
              productName: 'Scarce',
              quantityScaled: 9 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PaymentAllocation>[cashFor(165000)],
        ),
        throwsA(isA<InsufficientStockFailure>()),
      );

      // Neither product may have moved, and no partial invoice may exist.
      expect((await inventory.positionOf(good)).quantityScaled, 10 * scale);
      expect((await inventory.positionOf(scarce)).quantityScaled, scale);
      expect(await db.select(db.sales).get(), isEmpty);
      expect(await db.select(db.saleItems).get(), isEmpty);
      expect(await db.select(db.salePayments).get(), isEmpty);
      expect(await inventory.reconcile(), isEmpty);
    });

    test('preserves the historical cost when the average cost later changes',
        () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10, cost: 10000);

      final result = await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 2 * scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(30000)],
      );

      // A later, dearer purchase moves the product's average cost to 150.
      await inventory.apply(
        productId: id,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 20000,
      );

      final sale = await sales.findById(result.saleId);
      expect(sale!.lines.single.unitCostMinor, 10000);
      expect(sale.costTotalMinor, 20000);
      expect(sale.grossProfitMinor, 10000);
    });

    test('replays an idempotency key instead of selling twice', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final draft = draftFor(<SaleLine>[
        SaleLine(
          productId: id,
          productName: 'Widget',
          quantityScaled: 2 * scale,
          unitPriceMinor: 15000,
          unitCostMinor: 10000,
        ),
      ]);

      final first = await sales.post(
        draft: draft,
        payments: <PaymentAllocation>[cashFor(30000)],
        idempotencyKey: 'checkout-abc',
      );
      final second = await sales.post(
        draft: draft,
        payments: <PaymentAllocation>[cashFor(30000)],
        idempotencyKey: 'checkout-abc',
      );

      expect(first.outcome, SalePostOutcome.created);
      expect(second.outcome, SalePostOutcome.replayed);
      expect(second.saleId, first.saleId);
      expect(second.invoiceNo, first.invoiceNo);

      // The customer was charged once and the stock moved once.
      expect(await db.select(db.sales).get(), hasLength(1));
      expect((await inventory.positionOf(id)).quantityScaled, 8 * scale);
    });

    test('issues gap-free invoice numbers', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 20);
      final numbers = <String>[];
      for (var i = 0; i < 3; i++) {
        final result = await sales.post(
          draft: draftFor(<SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PaymentAllocation>[cashFor(15000)],
        );
        numbers.add(result.invoiceNo);
      }
      expect(numbers, <String>['INV-000001', 'INV-000002', 'INV-000003']);
    });

    test('records a customer debt for an unpaid balance', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);

      final result = await sales.post(
        draft: draftFor(
          <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ],
          customer: customerId,
        ),
        payments: <PaymentAllocation>[
          cashFor(10000),
          PaymentAllocation(
            paymentMethod: PaymentMethod.credit,
            currencyId: currencyId,
            amountMinor: 20000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 20000,
          ),
        ],
      );

      final sale = await sales.findById(result.saleId);
      expect(sale!.paidAmountMinor, 10000);
      expect(sale.baseOutstandingMinor, 20000);
      expect(sale.isCredit, isTrue);

      final entries = await db.select(db.customerAccountEntries).get();
      expect(entries, hasLength(1));
      expect(entries.single.direction, LedgerDirection.debit.wireValue);
      expect(entries.single.amountMinor, 20000);
    });

    test('refuses an unpaid sale with no customer to owe it', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);

      await expectLater(
        sales.post(
          draft: draftFor(<SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PaymentAllocation>[
            PaymentAllocation(
              paymentMethod: PaymentMethod.credit,
              currencyId: currencyId,
              amountMinor: 15000,
              exchangeRateNumerator: 1,
              exchangeRateDenominator: 1,
              baseAmountMinor: 15000,
            ),
          ],
        ),
        throwsA(isA<ValidationFailure>()),
      );

      expect(await db.select(db.sales).get(), isEmpty);
      expect((await inventory.positionOf(id)).quantityScaled, 10 * scale);
    });

    test('writes an audit entry', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(15000)],
      );

      final logs = await db.select(db.auditLogs).get();
      expect(logs, hasLength(1));
      expect(logs.single.action, 'sale.posted');
      expect(logs.single.entityType, 'sale');
    });
  });

  group('multi-currency sale', () {
    test('stores the rate and converts to base at posting time', () async {
      final usdId = await db.into(db.currencies).insert(
            CurrenciesCompanion.insert(
              code: 'USD',
              name: 'US Dollar',
              createdAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);

      // 1 USD = 3.75 SAR, stored as 375/100.
      final result = await sales.post(
        draft: SaleDraft(
          currencyId: usdId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 1000,
              unitCostMinor: 10000,
            ),
          ],
          exchangeRateNumerator: 375,
          exchangeRateDenominator: 100,
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: usdId,
            amountMinor: 2000,
            exchangeRateNumerator: 375,
            exchangeRateDenominator: 100,
            baseAmountMinor: 7500,
          ),
        ],
      );

      final sale = await sales.findById(result.saleId);
      expect(sale!.totalMinor, 2000);
      expect(sale.exchangeRateNumerator, 375);
      expect(sale.exchangeRateDenominator, 100);
      expect(sale.baseTotalMinor, 7500);
      expect(sale.payments.single.baseAmountMinor, 7500);
    });

    test('keeps a historical invoice unchanged when the rate moves', () async {
      final usdId = await db.into(db.currencies).insert(
            CurrenciesCompanion.insert(
              code: 'USD',
              name: 'US Dollar',
              createdAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);

      final result = await sales.post(
        draft: SaleDraft(
          currencyId: usdId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 1000,
              unitCostMinor: 10000,
            ),
          ],
          exchangeRateNumerator: 375,
          exchangeRateDenominator: 100,
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: usdId,
            amountMinor: 2000,
            exchangeRateNumerator: 375,
            exchangeRateDenominator: 100,
            baseAmountMinor: 7500,
          ),
        ],
      );

      // The configured rate changes to 4.00 SAR per USD.
      await db.into(db.exchangeRates).insert(
            ExchangeRatesCompanion.insert(
              currencyId: usdId,
              numerator: 400,
              denominator: 100,
              effectiveFrom: '2026-06-01T00:00:00.000Z',
              createdAt: '2026-06-01T00:00:00.000Z',
            ),
          );

      final sale = await sales.findById(result.saleId);
      expect(sale!.baseTotalMinor, 7500);
      expect(sale.exchangeRateNumerator, 375);
    });

    test('records a split payment across two currencies', () async {
      final usdId = await db.into(db.currencies).insert(
            CurrenciesCompanion.insert(
              code: 'USD',
              name: 'US Dollar',
              createdAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);

      final result = await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 2 * scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[
          // 249.97 SAR plus 13.34 USD at 3.75 = 300.00 SAR in total.
          cashFor(24997),
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: usdId,
            amountMinor: 1334,
            exchangeRateNumerator: 375,
            exchangeRateDenominator: 100,
            baseAmountMinor: 5003,
          ),
        ],
      );

      final sale = await sales.findById(result.saleId);
      expect(sale!.payments, hasLength(2));
      expect(sale.payments.first.currencyId, currencyId);
      expect(sale.payments.last.currencyId, usdId);
      expect(sale.payments.last.baseAmountMinor, 5003);
      expect(sale.basePaidAmountMinor, 30000);
      expect(sale.isFullyPaid, isTrue);
    });
  });

  group('voiding and returns', () {
    test('voiding restores stock and marks the invoice void', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final result = await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 3 * scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(45000)],
      );

      await sales.voidSale(saleId: result.saleId, reason: 'Cashier error');

      final sale = await sales.findById(result.saleId);
      expect(sale!.status, DocumentStatus.voided);
      expect(sale.notes, contains('Cashier error'));
      expect((await inventory.positionOf(id)).quantityScaled, 10 * scale);
      expect(await inventory.reconcile(), isEmpty);

      // The document is kept, not deleted.
      expect(await db.select(db.sales).get(), hasLength(1));
      expect(await db.select(db.saleItems).get(), hasLength(1));
    });

    test('voiding twice is refused', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final result = await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(15000)],
      );
      await sales.voidSale(saleId: result.saleId, reason: 'first');
      await expectLater(
        sales.voidSale(saleId: result.saleId, reason: 'second'),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('a voided invoice is hidden unless explicitly requested', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final result = await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(15000)],
      );
      await sales.voidSale(saleId: result.saleId, reason: 'test');

      expect((await sales.search()).totalCount, 0);
      expect(
        (await sales.search(
          filter: const SaleFilter(includeVoided: true),
        ))
            .totalCount,
        1,
      );
    });

    test('a credit return reduces the customer balance and restores stock',
        () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final result = await sales.post(
        draft: draftFor(
          <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ],
          customer: customerId,
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.credit,
            currencyId: currencyId,
            amountMinor: 30000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 30000,
          ),
        ],
      );

      final sale = await sales.findById(result.saleId);
      final returnNo = await sales.createReturn(
        saleId: result.saleId,
        quantityBySaleItem: <int, int>{sale!.lines.single.id!: scale},
        refundCash: false,
        reason: 'Damaged',
      );

      expect(returnNo, 'SR-000001');
      expect((await inventory.positionOf(id)).quantityScaled, 9 * scale);
      expect(await inventory.reconcile(), isEmpty);

      final entries = await db.select(db.customerAccountEntries).get();
      // A debit for the credit sale, then a credit for the return.
      expect(entries, hasLength(2));
      expect(entries.last.direction, LedgerDirection.credit.wireValue);
      expect(entries.last.amountMinor, 15000);
    });

    test('refuses a return larger than what was sold', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final result = await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 2 * scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(30000)],
      );
      final sale = await sales.findById(result.saleId);

      await expectLater(
        sales.createReturn(
          saleId: result.saleId,
          quantityBySaleItem: <int, int>{sale!.lines.single.id!: 5 * scale},
          refundCash: false,
        ),
        throwsA(isA<ValidationFailure>()),
      );
      expect((await inventory.positionOf(id)).quantityScaled, 8 * scale);
    });

    test('refuses a second return beyond the remaining quantity', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final result = await sales.post(
        draft: draftFor(
          <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 3 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ],
          customer: customerId,
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.credit,
            currencyId: currencyId,
            amountMinor: 45000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 45000,
          ),
        ],
      );
      final sale = await sales.findById(result.saleId);
      final itemId = sale!.lines.single.id!;

      await sales.createReturn(
        saleId: result.saleId,
        quantityBySaleItem: <int, int>{itemId: 2 * scale},
        refundCash: false,
      );

      // Only one unit remains returnable.
      await expectLater(
        sales.createReturn(
          saleId: result.saleId,
          quantityBySaleItem: <int, int>{itemId: 2 * scale},
          refundCash: false,
        ),
        throwsA(isA<ValidationFailure>()),
      );

      final ok = await sales.createReturn(
        saleId: result.saleId,
        quantityBySaleItem: <int, int>{itemId: scale},
        refundCash: false,
      );
      expect(ok, 'SR-000002');
      expect((await inventory.positionOf(id)).quantityScaled, 10 * scale);
    });

    test('refuses a cash refund with no open session', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final result = await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(15000)],
      );
      final sale = await sales.findById(result.saleId);

      await expectLater(
        sales.createReturn(
          saleId: result.saleId,
          quantityBySaleItem: <int, int>{sale!.lines.single.id!: scale},
          refundCash: true,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });
  });

  group('listing', () {
    test('filters by customer and unpaid status', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 20);

      await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(15000)],
      );
      await sales.post(
        draft: draftFor(
          <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ],
          customer: customerId,
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.credit,
            currencyId: currencyId,
            amountMinor: 15000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 15000,
          ),
        ],
      );

      expect(
        (await sales.search(filter: SaleFilter(customerId: customerId)))
            .totalCount,
        1,
      );
      expect(
        (await sales.search(filter: const SaleFilter(onlyUnpaid: true)))
            .totalCount,
        1,
      );
      expect((await sales.search()).totalCount, 2);
    });

    test('finds an invoice by its printed number', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 10);
      final result = await sales.post(
        draft: draftFor(<SaleLine>[
          SaleLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PaymentAllocation>[cashFor(15000)],
      );

      final found = await sales.findByInvoiceNo(result.invoiceNo);
      expect(found!.id, result.saleId);
      expect(await sales.findByInvoiceNo('INV-999999'), isNull);
    });

    test('pages the invoice list newest first', () async {
      final id = await stockedProduct(name: 'Widget', unitsOnHand: 20);
      for (var i = 0; i < 3; i++) {
        await sales.post(
          draft: draftFor(<SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PaymentAllocation>[cashFor(15000)],
        );
      }

      final page = await sales.search(request: const PageRequest(limit: 2));
      expect(page.items, hasLength(2));
      expect(page.totalCount, 3);
      expect(page.hasMore, isTrue);
      expect(page.items.first.invoiceNo, 'INV-000003');
    });
  });
}
