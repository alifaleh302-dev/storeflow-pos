import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/constants/enums.dart';
import 'package:storeflow_pos/core/errors/failures.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/features/cash_register/data/repositories/cash_register_service.dart';
import 'package:storeflow_pos/features/customers/data/repositories/customer_repository.dart';
import 'package:storeflow_pos/features/expenses/data/repositories/expense_repository.dart';
import 'package:storeflow_pos/features/inventory/data/inventory_service.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/features/purchases/data/repositories/purchase_repository.dart';
import 'package:storeflow_pos/features/purchases/domain/entities/purchase.dart';
import 'package:storeflow_pos/features/sales/data/repositories/sale_repository.dart';
import 'package:storeflow_pos/features/sales/domain/entities/sale.dart';
import 'package:storeflow_pos/features/sales/domain/services/sale_calculator.dart';
import 'package:storeflow_pos/features/suppliers/data/repositories/supplier_repository.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

void main() {
  late AppDatabase db;
  late InventoryService inventory;
  late ProductRepository products;
  late SaleRepository sales;
  late PurchaseRepository purchases;
  late CustomerRepository customers;
  late SupplierRepository suppliers;
  late ExpenseRepository expenses;
  late CashRegisterService register;

  const scale = Quantity.scale;
  late int currencyId;
  late int customerId;
  late int supplierId;

  setUp(() async {
    db = AppDatabase.memory();
    inventory = InventoryService(db);
    products = ProductRepository(db);
    sales = SaleRepository(db);
    purchases = PurchaseRepository(db);
    customers = CustomerRepository(db);
    suppliers = SupplierRepository(db);
    expenses = ExpenseRepository(db);
    register = CashRegisterService(db);

    final base = await (db.select(db.currencies)
          ..where((t) => t.isBase.equals(true)))
        .getSingle();
    currencyId = base.id;
    customerId = await customers.create(name: 'Khalid');
    supplierId = await suppliers.create(name: 'Acme Wholesale');
  });

  tearDown(() async {
    await db.close();
  });

  /// Stocks a product and returns its id.
  Future<int> stocked({String name = 'Widget', int units = 20}) async {
    final id = await products.create(
      name: name,
      purchaseCostMinor: 10000,
      sellingPriceMinor: 15000,
    );
    await inventory.apply(
      productId: id,
      movementType: MovementType.purchase,
      signedQuantityScaled: units * scale,
      referenceType: ReferenceType.purchase,
      allowNegativeStock: false,
      unitCost: 10000,
    );
    return id;
  }

  /// Posts a credit sale and returns the sale id.
  Future<int> creditSale({required int productId, int units = 2}) async {
    final result = await sales.post(
      draft: SaleDraft(
        currencyId: currencyId,
        currencyDecimalDigits: 2,
        customerId: customerId,
        lines: <SaleLine>[
          SaleLine(
            productId: productId,
            productName: 'Widget',
            quantityScaled: units * scale,
            unitPriceMinor: 15000,
            unitCostMinor: 10000,
          ),
        ],
      ),
      payments: <PaymentAllocation>[
        PaymentAllocation(
          paymentMethod: PaymentMethod.credit,
          currencyId: currencyId,
          amountMinor: units * 15000,
          exchangeRateNumerator: 1,
          exchangeRateDenominator: 1,
          baseAmountMinor: units * 15000,
        ),
      ],
    );
    return result.saleId;
  }

  group('customer records', () {
    test('creates, edits and deactivates', () async {
      final id = await customers.create(name: '  Sara  ', phone: '0555');
      final created = await customers.findById(id);
      expect(created!.name, 'Sara');
      expect(created.phone, '0555');
      expect(created.isActive, isTrue);

      await customers.update(id, address: 'Riyadh');
      final updated = await customers.findById(id);
      expect(updated!.address, 'Riyadh');
      expect(updated.phone, '0555');

      await customers.deactivate(id);
      expect((await customers.findById(id))!.isActive, isFalse);
      // A deactivated customer disappears from the default list. The search is
      // scoped by name because the database also seeds a walk-in customer.
      expect((await customers.search(searchTerm: 'Sara')).totalCount, 0);
      expect(
        (await customers.search(searchTerm: 'Sara', includeInactive: true))
            .totalCount,
        1,
      );
    });

    test('refuses a blank name', () async {
      await expectLater(
        customers.create(name: '  '),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('provides a reusable walk-in customer', () async {
      final first = await customers.walkInCustomerId();
      final second = await customers.walkInCustomerId();
      expect(first, second);
      expect((await customers.findById(first))!.isWalkIn, isTrue);
    });

    test('searches by name or phone', () async {
      await customers.create(name: 'Ahmed Ali', phone: '0501234567');
      await customers.create(name: 'Mona', phone: '0559999999');

      expect((await customers.search(searchTerm: 'Ahmed')).totalCount, 1);
      expect((await customers.search(searchTerm: '0559')).totalCount, 1);
      expect((await customers.search(searchTerm: 'zzz')).totalCount, 0);
    });
  });

  group('customer debts', () {
    test('a credit sale raises the balance', () async {
      final id = await stocked();
      await creditSale(productId: id);

      expect(await customers.balanceOf(customerId), 30000);
      final outstanding = await customers.withOutstandingBalance();
      expect(outstanding, hasLength(1));
      expect(outstanding.single.customer.id, customerId);
      expect(outstanding.single.isInDebt, isTrue);
    });

    test('a partial payment reduces the balance without creating a sale',
        () async {
      final id = await stocked();
      await creditSale(productId: id);

      await customers.recordPayment(
        customerId: customerId,
        paymentMethod: PaymentMethod.cash,
        currencyId: currencyId,
        amountMinor: 10000,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
      );

      expect(await customers.balanceOf(customerId), 20000);
      // A payment settles a debt; it is not a new sale.
      expect(await db.select(db.sales).get(), hasLength(1));
      expect(await db.select(db.customerPayments).get(), hasLength(1));
    });

    test('a full payment clears the balance', () async {
      final id = await stocked();
      await creditSale(productId: id);

      await customers.recordPayment(
        customerId: customerId,
        paymentMethod: PaymentMethod.cash,
        currencyId: currencyId,
        amountMinor: 30000,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
      );

      expect(await customers.balanceOf(customerId), 0);
      expect(await customers.withOutstandingBalance(), isEmpty);
    });

    test('overpayment leaves the customer in credit', () async {
      final id = await stocked();
      await creditSale(productId: id);

      await customers.recordPayment(
        customerId: customerId,
        paymentMethod: PaymentMethod.cash,
        currencyId: currencyId,
        amountMinor: 50000,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
      );

      expect(await customers.balanceOf(customerId), -20000);
      final outstanding = await customers.withOutstandingBalance();
      expect(outstanding.single.isInCredit, isTrue);
    });

    test('rejects a non-positive payment', () async {
      await expectLater(
        customers.recordPayment(
          customerId: customerId,
          paymentMethod: PaymentMethod.cash,
          currencyId: currencyId,
          amountMinor: 0,
          exchangeRateNumerator: 1,
          exchangeRateDenominator: 1,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('rejects a payment made with credit', () async {
      await expectLater(
        customers.recordPayment(
          customerId: customerId,
          paymentMethod: PaymentMethod.credit,
          currencyId: currencyId,
          amountMinor: 1000,
          exchangeRateNumerator: 1,
          exchangeRateDenominator: 1,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('converts a foreign-currency payment into base', () async {
      final usdId = await db.into(db.currencies).insert(
            CurrenciesCompanion.insert(
              code: 'USD',
              name: 'US Dollar',
              createdAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      final id = await stocked();
      await creditSale(productId: id);

      // 80.00 USD at 3.75 settles the whole 300.00 debt.
      await customers.recordPayment(
        customerId: customerId,
        paymentMethod: PaymentMethod.cash,
        currencyId: usdId,
        amountMinor: 8000,
        exchangeRateNumerator: 375,
        exchangeRateDenominator: 100,
      );

      expect(await customers.balanceOf(customerId), 0);
    });

    test('a statement lists the sale then the payment', () async {
      final id = await stocked();
      await creditSale(productId: id);
      await customers.recordPayment(
        customerId: customerId,
        paymentMethod: PaymentMethod.cash,
        currencyId: currencyId,
        amountMinor: 10000,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
      );

      final statement = await customers.statement(customerId);
      expect(statement, hasLength(2));
      expect(statement.first.direction, LedgerDirection.debit.wireValue);
      expect(statement.last.direction, LedgerDirection.credit.wireValue);
    });

    test('a credit sale return reduces the debt', () async {
      final id = await stocked();
      final saleId = await creditSale(productId: id);
      final sale = await sales.findById(saleId);

      await sales.createReturn(
        saleId: saleId,
        quantityBySaleItem: <int, int>{sale!.lines.single.id!: scale},
        refundCash: false,
      );

      // One of the two units came back, so half the debt is gone.
      expect(await customers.balanceOf(customerId), 15000);
    });
  });

  group('supplier payments', () {
    test('a payment reduces what the store owes', () async {
      final id = await stocked();
      await purchases.post(
        draft: PurchaseDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          supplierId: supplierId,
          lines: <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 10 * scale,
              unitCostMinor: 10000,
            ),
          ],
        ),
        payments: <PurchasePayment>[
          PurchasePayment(
            paymentMethod: PaymentMethod.credit,
            currencyId: currencyId,
            amountMinor: 100000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 100000,
          ),
        ],
      );

      expect(await suppliers.balanceOf(supplierId), 100000);

      await customers.recordSupplierPayment(
        supplierId: supplierId,
        paymentMethod: PaymentMethod.cash,
        currencyId: currencyId,
        amountMinor: 40000,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
      );

      expect(await suppliers.balanceOf(supplierId), 60000);
    });

    test('refuses a payment to a missing supplier', () async {
      await expectLater(
        customers.recordSupplierPayment(
          supplierId: 999999,
          paymentMethod: PaymentMethod.cash,
          currencyId: currencyId,
          amountMinor: 1000,
          exchangeRateNumerator: 1,
          exchangeRateDenominator: 1,
        ),
        throwsA(isA<NotFoundFailure>()),
      );
    });
  });

  group('expenses', () {
    test('records an expense with a generated number', () async {
      final categories = await expenses.categories();
      final rent = categories.firstWhere((c) => c.code == 'rent');

      final no = await expenses.record(
        description: 'November rent',
        amountMinor: 250000,
        currencyId: currencyId,
        paymentMethod: PaymentMethod.bankTransfer,
        categoryId: rent.id,
      );

      expect(no, 'EXP-000001');
      expect(await expenses.totalBaseMinor(), 250000);

      final page = await expenses.search();
      expect(page.items.single.description, 'November rent');
      expect(page.items.single.baseAmount, 250000);
    });

    test('rejects a blank description and a non-positive amount', () async {
      await expectLater(
        expenses.record(
          description: '   ',
          amountMinor: 1000,
          currencyId: currencyId,
          paymentMethod: PaymentMethod.cash,
        ),
        throwsA(isA<ValidationFailure>()),
      );
      await expectLater(
        expenses.record(
          description: 'Power',
          amountMinor: 0,
          currencyId: currencyId,
          paymentMethod: PaymentMethod.cash,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('converts a foreign-currency expense into base', () async {
      final usdId = await db.into(db.currencies).insert(
            CurrenciesCompanion.insert(
              code: 'USD',
              name: 'US Dollar',
              createdAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );

      await expenses.record(
        description: 'Imported parts',
        amountMinor: 10000,
        currencyId: usdId,
        paymentMethod: PaymentMethod.cash,
        exchangeRateNumerator: 375,
        exchangeRateDenominator: 100,
      );

      expect(await expenses.totalBaseMinor(), 37500);
    });

    test('groups totals by category', () async {
      final categories = await expenses.categories();
      final rent = categories.firstWhere((c) => c.code == 'rent');
      final power = categories.firstWhere((c) => c.code == 'electricity');

      await expenses.record(
        description: 'Rent',
        amountMinor: 100000,
        currencyId: currencyId,
        paymentMethod: PaymentMethod.cash,
        categoryId: rent.id,
      );
      await expenses.record(
        description: 'Power',
        amountMinor: 30000,
        currencyId: currencyId,
        paymentMethod: PaymentMethod.cash,
        categoryId: power.id,
      );

      final totals = await expenses.totalsByCategory();
      expect(totals, hasLength(2));
      expect(totals.first.categoryName, 'Rent');
      expect(totals.first.totalBaseMinor, 100000);
    });

    test('a cash expense leaves the drawer', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 100000,
        currencyId: currencyId,
      );

      await expenses.record(
        description: 'Fuel',
        amountMinor: 20000,
        currencyId: currencyId,
        paymentMethod: PaymentMethod.cash,
        cashSessionId: sessionId,
      );

      final summary = await register.summary(sessionId);
      expect(summary.cashOutMinor, 20000);
      expect(summary.expectedCashMinor, 80000);
    });

    test('a transfer expense does not touch the drawer', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 100000,
        currencyId: currencyId,
      );

      await expenses.record(
        description: 'Rent by transfer',
        amountMinor: 50000,
        currencyId: currencyId,
        paymentMethod: PaymentMethod.bankTransfer,
        cashSessionId: sessionId,
      );

      final summary = await register.summary(sessionId);
      expect(summary.cashOutMinor, 0);
      expect(summary.expectedCashMinor, 100000);
    });
  });

  group('cash register', () {
    test('opens a session and refuses a second one', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 50000,
        currencyId: currencyId,
      );
      final session = await register.currentSession();
      expect(session!.id, sessionId);
      expect(session.status, CashSessionStatus.open.wireValue);

      await expectLater(
        register.openSession(
          openingBalanceMinor: 10000,
          currencyId: currencyId,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('a cash sale adds to the drawer, a credit sale does not', () async {
      final id = await stocked();
      final sessionId = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );

      // A cash sale.
      await sales.post(
        draft: SaleDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ],
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: currencyId,
            amountMinor: 15000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 15000,
          ),
        ],
        cashSessionId: sessionId,
      );

      // A credit sale must not be treated as collected cash.
      await creditSale(productId: id, units: 2);

      final summary = await register.summary(sessionId);
      expect(summary.cashInMinor, 15000);
      expect(summary.expectedCashMinor, 15000);
    });

    test('a debt collection adds to the drawer', () async {
      final id = await stocked();
      await creditSale(productId: id);
      final sessionId = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );

      await customers.recordPayment(
        customerId: customerId,
        paymentMethod: PaymentMethod.cash,
        currencyId: currencyId,
        amountMinor: 10000,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
        cashSessionId: sessionId,
      );

      expect((await register.summary(sessionId)).cashInMinor, 10000);
    });

    test('a cash purchase takes money out of the drawer', () async {
      final id = await stocked();
      final sessionId = await register.openSession(
        openingBalanceMinor: 200000,
        currencyId: currencyId,
      );

      await purchases.post(
        draft: PurchaseDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          supplierId: supplierId,
          lines: <PurchaseLine>[
            PurchaseLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 5 * scale,
              unitCostMinor: 10000,
            ),
          ],
        ),
        payments: <PurchasePayment>[
          PurchasePayment(
            paymentMethod: PaymentMethod.cash,
            currencyId: currencyId,
            amountMinor: 50000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 50000,
          ),
        ],
        cashSessionId: sessionId,
      );

      expect((await register.summary(sessionId)).cashOutMinor, 50000);
    });

    test('records a manual deposit and withdrawal', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );

      await register.recordMovement(
        sessionId: sessionId,
        type: CashTransactionType.deposit,
        amountMinor: 30000,
        currencyId: currencyId,
      );
      await register.recordMovement(
        sessionId: sessionId,
        type: CashTransactionType.withdrawal,
        amountMinor: 10000,
        currencyId: currencyId,
      );

      final summary = await register.summary(sessionId);
      expect(summary.cashInMinor, 30000);
      expect(summary.cashOutMinor, 10000);
      expect(summary.expectedCashMinor, 20000);
    });

    test('closes a session and reports the difference', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 100000,
        currencyId: currencyId,
      );
      await register.recordMovement(
        sessionId: sessionId,
        type: CashTransactionType.deposit,
        amountMinor: 20000,
        currencyId: currencyId,
      );

      final closed = await register.closeSession(
        sessionId: sessionId,
        actualCashMinor: 115000,
      );

      expect(closed.expectedCashMinor, 120000);
      expect(closed.session.actualCash, 115000);
      // The drawer is 50.00 short.
      expect(closed.differenceMinor, -5000);
      expect(closed.session.status, CashSessionStatus.closed.wireValue);
      expect(closed.session.closedAt, isNotNull);
    });

    test('refuses to close a session twice', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );
      await register.closeSession(sessionId: sessionId, actualCashMinor: 0);
      await expectLater(
        register.closeSession(sessionId: sessionId, actualCashMinor: 0),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('refuses a movement on a closed session', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );
      await register.closeSession(sessionId: sessionId, actualCashMinor: 0);
      await expectLater(
        register.recordMovement(
          sessionId: sessionId,
          type: CashTransactionType.deposit,
          amountMinor: 1000,
          currencyId: currencyId,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('reports no open session rather than guessing', () async {
      await expectLater(
        register.requireOpenSession(),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('keeps a session history', () async {
      final first = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );
      await register.closeSession(sessionId: first, actualCashMinor: 0);
      final second = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );

      final history = await register.history();
      expect(history, hasLength(2));
      // Newest first.
      expect(history.first.id, second);
    });
  });

  group('expense totals feed profit', () {
    test('expenses are summed separately from cost of goods', () async {
      final id = await stocked();
      await sales.post(
        draft: SaleDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ],
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: currencyId,
            amountMinor: 30000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 30000,
          ),
        ],
      );
      await expenses.record(
        description: 'Power',
        amountMinor: 5000,
        currencyId: currencyId,
        paymentMethod: PaymentMethod.cash,
      );

      // Gross profit is 300.00 - 200.00 = 100.00, and the 50.00 expense is
      // separate from it.
      final page = await sales.search();
      expect(page.items.single.grossProfitMinor, 10000);
      expect(await expenses.totalBaseMinor(), 5000);
    });
  });
}
