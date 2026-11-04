import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/constants/enums.dart';
import 'package:storeflow_pos/core/errors/failures.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/core/utils/pagination.dart';
import 'package:storeflow_pos/features/inventory/data/inventory_service.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/features/purchases/data/repositories/purchase_repository.dart';
import 'package:storeflow_pos/features/purchases/domain/entities/purchase.dart';
import 'package:storeflow_pos/features/suppliers/data/repositories/supplier_repository.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

void main() {
  late AppDatabase db;
  late InventoryService inventory;
  late ProductRepository products;
  late PurchaseRepository purchases;
  late SupplierRepository suppliers;

  const scale = Quantity.scale;
  late int currencyId;
  late int supplierId;

  setUp(() async {
    db = AppDatabase.memory();
    inventory = InventoryService(db);
    products = ProductRepository(db);
    purchases = PurchaseRepository(db);
    suppliers = SupplierRepository(db);

    final base = await (db.select(db.currencies)
          ..where((t) => t.isBase.equals(true)))
        .getSingle();
    currencyId = base.id;
    supplierId = await suppliers.create(name: 'Acme Wholesale');
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> newProduct({String name = 'Widget', int price = 15000}) {
    return products.create(
      name: name,
      purchaseCostMinor: 0,
      sellingPriceMinor: price,
    );
  }

  PurchaseDraft draftFor(
    List<PurchaseLine> lines, {
    int? supplier,
    int discount = 0,
    int additionalCost = 0,
  }) {
    return PurchaseDraft(
      currencyId: currencyId,
      currencyDecimalDigits: 2,
      supplierId: supplier,
      lines: lines,
      discountMinor: discount,
      additionalCostMinor: additionalCost,
    );
  }

  PurchasePayment cashFor(int amountMinor) => PurchasePayment(
        paymentMethod: PaymentMethod.cash,
        currencyId: currencyId,
        amountMinor: amountMinor,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
        baseAmountMinor: amountMinor,
      );

  PurchasePayment creditFor(int amountMinor) => PurchasePayment(
        paymentMethod: PaymentMethod.credit,
        currencyId: currencyId,
        amountMinor: amountMinor,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
        baseAmountMinor: amountMinor,
      );

  group('PurchaseDraft arithmetic', () {
    test('totals lines, discount and additional cost', () {
      final draft = draftFor(
        <PurchaseLine>[
          const PurchaseLine(
            productId: 1,
            productName: 'A',
            quantityScaled: 10 * scale,
            unitCostMinor: 10000,
          ),
          const PurchaseLine(
            productId: 2,
            productName: 'B',
            quantityScaled: 5 * scale,
            unitCostMinor: 2000,
          ),
        ],
        discount: 5000,
        additionalCost: 3000,
      );

      expect(draft.subtotalMinor, 100000 + 10000);
      // 110000 - 5000 + 3000
      expect(draft.totalMinor, 108000);
    });

    test('merges a repeated product and re-weights the cost', () {
      var draft = draftFor(<PurchaseLine>[
        const PurchaseLine(
          productId: 1,
          productName: 'A',
          quantityScaled: 10 * scale,
          unitCostMinor: 10000,
        ),
      ]);
      draft = draft.addLine(
        const PurchaseLine(
          productId: 1,
          productName: 'A',
          quantityScaled: 10 * scale,
          unitCostMinor: 12000,
        ),
      );

      expect(draft.lines, hasLength(1));
      expect(draft.lines.single.quantityScaled, 20 * scale);
      // (10*100 + 10*120) / 20 = 110
      expect(draft.lines.single.unitCostMinor, 11000);
      expect(draft.lines.single.netMinor, 220000);
    });

    test('never lets the total go negative', () {
      final draft = draftFor(
        <PurchaseLine>[
          const PurchaseLine(
            productId: 1,
            productName: 'A',
            quantityScaled: scale,
            unitCostMinor: 1000,
          ),
        ],
        discount: 99999,
      );
      expect(draft.totalMinor, 0);
    });

    test('removes a line when its quantity reaches zero', () {
      var draft = draftFor(<PurchaseLine>[
        const PurchaseLine(
          productId: 1,
          productName: 'A',
          quantityScaled: scale,
          unitCostMinor: 1000,
        ),
      ]);
      draft = draft.setQuantity(1, 0);
      expect(draft.isEmpty, isTrue);
    });
  });

  group('posting a purchase', () {
    test('creates the invoice, raises stock and sets the cost', () async {
      final id = await newProduct();

      final result = await purchases.post(
        draft: draftFor(
          <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
          ],
          supplier: supplierId,
        ),
        payments: <PurchasePayment>[cashFor(100000)],
      );

      expect(result.invoiceNo, 'PUR-000001');

      final position = await inventory.positionOf(id);
      expect(position.quantityScaled, 10 * scale);
      expect(position.averageCostMinor, 10000);
      expect(await inventory.reconcile(), isEmpty);

      final purchase = await purchases.findById(result.purchaseId);
      expect(purchase!.totalMinor, 100000);
      expect(purchase.supplierName, 'Acme Wholesale');
      expect(purchase.isFullyPaid, isTrue);
      expect(purchase.lines.single.unitCostMinor, 10000);
    });

    test('weights the average cost across two receipts', () async {
      final id = await newProduct();

      await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(100000)],
      );
      await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 12000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(120000)],
      );

      // (10*100 + 10*120) / 20 = 110
      final position = await inventory.positionOf(id);
      expect(position.quantityScaled, 20 * scale);
      expect(position.averageCostMinor, 11000);
      expect(await inventory.reconcile(), isEmpty);
    });

    test('folds an invoice discount into the unit cost', () async {
      final id = await newProduct();

      await purchases.post(
        draft: draftFor(
          <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
          ],
          discount: 5000,
        ),
        payments: <PurchasePayment>[cashFor(95000)],
      );

      // 95000 paid for 10 units is 9500 each, not the 10000 on the line.
      expect((await inventory.positionOf(id)).averageCostMinor, 9500);
    });

    test('folds freight into the unit cost', () async {
      final id = await newProduct();

      await purchases.post(
        draft: draftFor(
          <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
          ],
          additionalCost: 3000,
        ),
        payments: <PurchasePayment>[cashFor(103000)],
      );

      // 103000 for 10 units is 10300 each.
      expect((await inventory.positionOf(id)).averageCostMinor, 10300);
    });

    test('spreads a discount across lines in proportion to their value',
        () async {
      final a = await newProduct(name: 'A');
      final b = await newProduct(name: 'B');

      await purchases.post(
        draft: draftFor(
          <PurchaseLine>[
            PurchaseLine(
              productId: a,
              productName: 'A',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
            PurchaseLine(
              productId: b,
              productName: 'B',
              quantityScaled: 10 * scale,
              unitCostMinor: 5000,
            ),
          ],
          discount: 15000,
        ),
        payments: <PurchasePayment>[cashFor(135000)],
      );

      // A is two thirds of the value, so it takes two thirds of the discount.
      expect((await inventory.positionOf(a)).averageCostMinor, 9000);
      expect((await inventory.positionOf(b)).averageCostMinor, 4500);
    });

    test('records a supplier payable for an unpaid purchase', () async {
      final id = await newProduct();

      await purchases.post(
        draft: draftFor(
          <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
          ],
          supplier: supplierId,
        ),
        payments: <PurchasePayment>[
          creditFor(40000),
          cashFor(60000),
        ],
      );

      // Only the cash portion counts as paid.
      expect(await suppliers.balanceOf(supplierId), 40000);
      final outstanding = await suppliers.withOutstandingBalance();
      expect(outstanding, hasLength(1));
      expect(outstanding.single.balanceBaseMinor, 40000);
    });

    test('refuses an unpaid purchase with no supplier', () async {
      final id = await newProduct();
      await expectLater(
        purchases.post(
          draft: draftFor(<PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PurchasePayment>[creditFor(100000)],
        ),
        throwsA(isA<ValidationFailure>()),
      );
      expect((await inventory.positionOf(id)).quantityScaled, 0);
      expect(await db.select(db.purchases).get(), isEmpty);
    });

    test('rejects an empty purchase', () async {
      await expectLater(
        purchases.post(
          draft: draftFor(const <PurchaseLine>[]),
          payments: <PurchasePayment>[cashFor(0)],
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('rejects an overpayment', () async {
      final id = await newProduct();
      await expectLater(
        purchases.post(
          draft: draftFor(<PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: scale,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PurchasePayment>[cashFor(20000)],
        ),
        throwsA(isA<ValidationFailure>()),
      );
      expect(await db.select(db.purchases).get(), isEmpty);
    });

    test('rejects an underpayment with no credit tender', () async {
      final id = await newProduct();
      await expectLater(
        purchases.post(
          draft: draftFor(<PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: scale,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PurchasePayment>[cashFor(5000)],
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('rolls back the whole purchase when a line fails', () async {
      final good = await newProduct(name: 'Good');
      // A line referring to a product that does not exist must fail the lot.
      await expectLater(
        purchases.post(
          draft: draftFor(<PurchaseLine>[
            PurchaseLine(
              productId: good,
              productName: 'Good',
              quantityScaled: 5 * scale,
              unitCostMinor: 10000,
            ),
            const PurchaseLine(
              productId: 999999,
              productName: 'Ghost',
              quantityScaled: scale,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PurchasePayment>[cashFor(60000)],
        ),
        throwsA(isA<NotFoundFailure>()),
      );

      expect((await inventory.positionOf(good)).quantityScaled, 0);
      expect(await db.select(db.purchases).get(), isEmpty);
      expect(await db.select(db.purchaseItems).get(), isEmpty);
      expect(await inventory.reconcile(), isEmpty);
    });

    test('replays an idempotency key instead of receiving twice', () async {
      final id = await newProduct();
      final draft = draftFor(<PurchaseLine>[
        PurchaseLine(
          productId: id,
          productName: 'Widget',
          quantityScaled: 10 * scale,
          unitCostMinor: 10000,
        ),
      ]);

      final first = await purchases.post(
        draft: draft,
        payments: <PurchasePayment>[cashFor(100000)],
        idempotencyKey: 'receipt-1',
      );
      final second = await purchases.post(
        draft: draft,
        payments: <PurchasePayment>[cashFor(100000)],
        idempotencyKey: 'receipt-1',
      );

      expect(second.wasReplay, isTrue);
      expect(second.purchaseId, first.purchaseId);
      expect((await inventory.positionOf(id)).quantityScaled, 10 * scale);
      expect(await db.select(db.purchases).get(), hasLength(1));
    });

    test('records a cash movement out of the drawer', () async {
      final id = await newProduct();
      final sessionId = await db.into(db.cashSessions).insert(
            CashSessionsCompanion.insert(
              openingBalance: 500000,
              currencyId: currencyId,
              status: CashSessionStatus.open.wireValue,
              openedAt: '2026-01-01T00:00:00.000Z',
            ),
          );

      await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(100000)],
        cashSessionId: sessionId,
      );

      final rows = await db.select(db.cashTransactions).get();
      expect(rows, hasLength(1));
      // Paying a supplier takes money out of the till.
      expect(rows.single.amountBase, -100000);
      expect(
        rows.single.transactionType,
        CashTransactionType.supplierPayment.wireValue,
      );
    });
  });

  group('multi-currency purchase', () {
    test('stores the rate and converts the payable to base', () async {
      final usdId = await db.into(db.currencies).insert(
            CurrenciesCompanion.insert(
              code: 'USD',
              name: 'US Dollar',
              createdAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      final id = await newProduct();

      final result = await purchases.post(
        draft: PurchaseDraft(
          currencyId: usdId,
          currencyDecimalDigits: 2,
          supplierId: supplierId,
          lines: <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 1000,
            ),
          ],
          exchangeRateNumerator: 375,
          exchangeRateDenominator: 100,
        ),
        payments: <PurchasePayment>[
          PurchasePayment(
            paymentMethod: PaymentMethod.credit,
            currencyId: usdId,
            amountMinor: 10000,
            exchangeRateNumerator: 375,
            exchangeRateDenominator: 100,
            baseAmountMinor: 37500,
          ),
        ],
      );

      final purchase = await purchases.findById(result.purchaseId);
      expect(purchase!.totalMinor, 10000);
      expect(purchase.baseTotalMinor, 37500);
      expect(purchase.exchangeRateNumerator, 375);
      // The supplier is owed 375.00 SAR, not 100.00.
      expect(await suppliers.balanceOf(supplierId), 37500);
    });
  });

  group('voiding a purchase', () {
    test('removes the stock and marks the invoice void', () async {
      final id = await newProduct();
      final result = await purchases.post(
        draft: draftFor(
          <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
          ],
          supplier: supplierId,
        ),
        payments: <PurchasePayment>[creditFor(100000)],
      );

      await purchases.voidPurchase(
        purchaseId: result.purchaseId,
        reason: 'Wrong delivery',
      );

      final purchase = await purchases.findById(result.purchaseId);
      expect(purchase!.isVoided, isTrue);
      expect((await inventory.positionOf(id)).quantityScaled, 0);
      expect(await inventory.reconcile(), isEmpty);
      // The payable is cleared by the reversal.
      expect(await suppliers.balanceOf(supplierId), 0);
      // The document is kept.
      expect(await db.select(db.purchases).get(), hasLength(1));
    });

    test('restores the average cost of an earlier receipt', () async {
      final id = await newProduct();

      await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(100000)],
      );

      final second = await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 12000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(120000)],
      );

      expect((await inventory.positionOf(id)).averageCostMinor, 11000);

      await purchases.voidPurchase(
        purchaseId: second.purchaseId,
        reason: 'Priced wrong',
      );

      // Unwinding the dearer receipt must leave the original 100.00 average.
      final position = await inventory.positionOf(id);
      expect(position.quantityScaled, 10 * scale);
      expect(position.averageCostMinor, 10000);
      expect(await inventory.reconcile(), isEmpty);
    });

    test('voiding twice is refused', () async {
      final id = await newProduct();
      final result = await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(100000)],
      );
      await purchases.voidPurchase(purchaseId: result.purchaseId, reason: 'a');
      await expectLater(
        purchases.voidPurchase(purchaseId: result.purchaseId, reason: 'b'),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('refuses to void when the stock has already been sold', () async {
      final id = await newProduct();
      final result = await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(100000)],
      );

      // Sell most of it, leaving too little to give back.
      await inventory.apply(
        productId: id,
        movementType: MovementType.sale,
        signedQuantityScaled: -9 * scale,
        referenceType: ReferenceType.sale,
        allowNegativeStock: false,
      );

      await expectLater(
        purchases.voidPurchase(purchaseId: result.purchaseId, reason: 'x'),
        throwsA(isA<InsufficientStockFailure>()),
      );

      // The refusal must leave everything untouched.
      final purchase = await purchases.findById(result.purchaseId);
      expect(purchase!.isVoided, isFalse);
      expect((await inventory.positionOf(id)).quantityScaled, scale);
      expect(await inventory.reconcile(), isEmpty);
    });
  });

  group('supplier returns', () {
    test('removes stock and reduces the payable', () async {
      final id = await newProduct();
      final result = await purchases.post(
        draft: draftFor(
          <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
          ],
          supplier: supplierId,
        ),
        payments: <PurchasePayment>[creditFor(100000)],
      );
      final purchase = await purchases.findById(result.purchaseId);

      final returnNo = await purchases.createReturn(
        purchaseId: result.purchaseId,
        quantityByPurchaseItem: <int, int>{
          purchase!.lines.single.id!: 4 * scale,
        },
        reason: 'Damaged in transit',
      );

      expect(returnNo, 'PR-000001');
      expect((await inventory.positionOf(id)).quantityScaled, 6 * scale);
      // 400.00 of the 1000.00 payable is settled by the return.
      expect(await suppliers.balanceOf(supplierId), 60000);
      expect(await inventory.reconcile(), isEmpty);
    });

    test('refuses a return larger than was received', () async {
      final id = await newProduct();
      final result = await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(100000)],
      );
      final purchase = await purchases.findById(result.purchaseId);

      await expectLater(
        purchases.createReturn(
          purchaseId: result.purchaseId,
          quantityByPurchaseItem: <int, int>{
            purchase!.lines.single.id!: 20 * scale,
          },
        ),
        throwsA(isA<ValidationFailure>()),
      );
      expect((await inventory.positionOf(id)).quantityScaled, 10 * scale);
    });

    test('caps a second return at the remaining quantity', () async {
      final id = await newProduct();
      final result = await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(100000)],
      );
      final purchase = await purchases.findById(result.purchaseId);
      final itemId = purchase!.lines.single.id!;

      await purchases.createReturn(
        purchaseId: result.purchaseId,
        quantityByPurchaseItem: <int, int>{itemId: 7 * scale},
      );
      await expectLater(
        purchases.createReturn(
          purchaseId: result.purchaseId,
          quantityByPurchaseItem: <int, int>{itemId: 5 * scale},
        ),
        throwsA(isA<ValidationFailure>()),
      );

      await purchases.createReturn(
        purchaseId: result.purchaseId,
        quantityByPurchaseItem: <int, int>{itemId: 3 * scale},
      );
      expect((await inventory.positionOf(id)).quantityScaled, 0);
    });

    test('unwinds the average cost when goods go back', () async {
      final id = await newProduct();

      await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(100000)],
      );
      final second = await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 10 * scale,
            unitCostMinor: 12000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(120000)],
      );
      final purchase = await purchases.findById(second.purchaseId);

      // Send back the whole dearer receipt.
      await purchases.createReturn(
        purchaseId: second.purchaseId,
        quantityByPurchaseItem: <int, int>{
          purchase!.lines.single.id!: 10 * scale,
        },
      );

      final position = await inventory.positionOf(id);
      expect(position.quantityScaled, 10 * scale);
      expect(position.averageCostMinor, 10000);
      expect(await inventory.reconcile(), isEmpty);
    });
  });

  group('supplier records', () {
    test('creates, edits and deactivates', () async {
      final id = await suppliers.create(name: '  Beta Ltd  ', phone: '0500000000');
      final created = await suppliers.findById(id);
      expect(created!.name, 'Beta Ltd');
      expect(created.phone, '0500000000');
      expect(created.isActive, isTrue);

      await suppliers.update(id, name: 'Beta Trading', email: 'a@b.com');
      final updated = await suppliers.findById(id);
      expect(updated!.name, 'Beta Trading');
      expect(updated.email, 'a@b.com');
      // The untouched phone is preserved.
      expect(updated.phone, '0500000000');

      await suppliers.deactivate(id);
      expect((await suppliers.findById(id))!.isActive, isFalse);
      // A deactivated supplier is hidden from the default list.
      expect((await suppliers.search()).totalCount, 1);
      expect(
        (await suppliers.search(includeInactive: true)).totalCount,
        2,
      );
    });

    test('refuses a blank name', () async {
      await expectLater(
        suppliers.create(name: '   '),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('searches by name and escapes wildcards', () async {
      await suppliers.create(name: '100% Wholesale');
      await suppliers.create(name: 'Ordinary Co');

      expect((await suppliers.search(searchTerm: '100%')).totalCount, 1);
      // A bare '%' must be treated as a literal, so it matches only the supplier
      // whose name contains one - not both suppliers, which is what an
      // unescaped wildcard would do.
      expect((await suppliers.search(searchTerm: '%')).totalCount, 1);
      expect((await suppliers.search(searchTerm: 'zzz')).totalCount, 0);
      expect((await suppliers.search(searchTerm: 'Ordinary')).totalCount, 1);
    });

    test('builds a statement oldest first', () async {
      final id = await newProduct();
      await purchases.post(
        draft: draftFor(
          <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
          ],
          supplier: supplierId,
        ),
        payments: <PurchasePayment>[creditFor(100000)],
      );

      final statement = await suppliers.statement(supplierId);
      expect(statement, hasLength(1));
      expect(statement.single.amountMinor, 100000);
      expect(statement.single.direction, LedgerDirection.credit.wireValue);
    });
  });

  group('listing purchases', () {
    test('filters by supplier and unpaid status', () async {
      final id = await newProduct();
      await purchases.post(
        draft: draftFor(<PurchaseLine>[
          PurchaseLine(
            productId: id,
            productName: 'Widget',
            quantityScaled: 5 * scale,
            unitCostMinor: 10000,
          ),
        ]),
        payments: <PurchasePayment>[cashFor(50000)],
      );
      await purchases.post(
        draft: draftFor(
          <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 5 * scale,
              unitCostMinor: 10000,
            ),
          ],
          supplier: supplierId,
        ),
        payments: <PurchasePayment>[creditFor(50000)],
      );

      expect(
        (await purchases.search(
          filter: PurchaseFilter(supplierId: supplierId),
        ))
            .totalCount,
        1,
      );
      expect(
        (await purchases.search(filter: const PurchaseFilter(onlyUnpaid: true)))
            .totalCount,
        1,
      );
      expect((await purchases.search()).totalCount, 2);
    });

    test('pages newest first', () async {
      final id = await newProduct();
      for (var i = 0; i < 3; i++) {
        await purchases.post(
          draft: draftFor(<PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: scale,
              unitCostMinor: 10000,
            ),
          ]),
          payments: <PurchasePayment>[cashFor(10000)],
        );
      }

      final page =
          await purchases.search(request: const PageRequest(limit: 2));
      expect(page.items, hasLength(2));
      expect(page.totalCount, 3);
      expect(page.items.first.invoiceNo, 'PUR-000003');
    });
  });
}
