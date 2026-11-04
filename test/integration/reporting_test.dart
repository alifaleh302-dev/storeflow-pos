import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/constants/enums.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/core/utils/csv.dart';
import 'package:storeflow_pos/features/cash_register/data/repositories/cash_register_service.dart';
import 'package:storeflow_pos/features/customers/data/repositories/customer_repository.dart';
import 'package:storeflow_pos/features/dashboard/data/dashboard_repository.dart';
import 'package:storeflow_pos/features/dashboard/domain/entities/dashboard_period.dart';
import 'package:storeflow_pos/features/expenses/data/repositories/expense_repository.dart';
import 'package:storeflow_pos/features/inventory/data/inventory_service.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/features/purchases/data/repositories/purchase_repository.dart';
import 'package:storeflow_pos/features/purchases/domain/entities/purchase.dart';
import 'package:storeflow_pos/features/reports/data/repositories/reporting_service.dart';
import 'package:storeflow_pos/features/sales/data/repositories/sale_repository.dart';
import 'package:storeflow_pos/features/sales/domain/entities/sale.dart';
import 'package:storeflow_pos/features/sales/domain/services/sale_calculator.dart';
import 'package:storeflow_pos/features/suppliers/data/repositories/supplier_repository.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

void main() {
  const scale = Quantity.scale;

  late AppDatabase db;
  late ReportingService reports;
  late DashboardRepository dashboard;
  late ProductRepository products;
  late InventoryService inventory;
  late SaleRepository sales;
  late PurchaseRepository purchases;
  late CustomerRepository customers;
  late SupplierRepository suppliers;
  late ExpenseRepository expenses;
  late CashRegisterService register;

  late int currencyId;
  late int widgetId;
  late int gadgetId;
  late int customerId;

  /// The reporting window, wide enough to include everything the tests post.
  final range = DateRange(
    start: DateTime.utc(2026, 1, 1),
    endExclusive: DateTime.utc(2027, 1, 1),
  );

  setUp(() async {
    db = AppDatabase.memory();
    reports = ReportingService(db);
    dashboard = DashboardRepository(db);
    products = ProductRepository(db);
    inventory = InventoryService(db);
    sales = SaleRepository(db);
    purchases = PurchaseRepository(db);
    customers = CustomerRepository(db);
    suppliers = SupplierRepository(db);
    expenses = ExpenseRepository(db);
    register = CashRegisterService(db);

    final baseCurrency = await (db.select(db.currencies)
          ..where((t) => t.isBase.equals(true)))
        .getSingle();
    currencyId = baseCurrency.id;

    // A small known catalogue: two products, stocked at a known cost.
    widgetId = await products.create(
      name: 'Widget',
      purchaseCostMinor: 10000,
      sellingPriceMinor: 15000,
    );
    gadgetId = await products.create(
      name: 'Gadget',
      purchaseCostMinor: 5000,
      sellingPriceMinor: 8000,
    );
    for (final entry in <(int, int)>[(widgetId, 100), (gadgetId, 100)]) {
      await inventory.apply(
        productId: entry.$1,
        movementType: MovementType.purchase,
        signedQuantityScaled: entry.$2 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: entry.$1 == widgetId ? 10000 : 5000,
      );
    }
    customerId = await customers.create(name: 'Khalid');
  });

  tearDown(() async {
    await db.close();
  });

  /// Posts a sale of [units] of a product, paid by [method].
  Future<int> sell({
    required int productId,
    required int units,
    required int unitPriceMinor,
    required int unitCostMinor,
    PaymentMethod method = PaymentMethod.cash,
    int? customer,
    int? cashSessionId,
  }) async {
    final total = units * unitPriceMinor;
    final result = await sales.post(
      draft: SaleDraft(
        currencyId: currencyId,
        currencyDecimalDigits: 2,
        customerId: customer,
        lines: <SaleLine>[
          SaleLine(
            productId: productId,
            productName: productId == widgetId ? 'Widget' : 'Gadget',
            quantityScaled: units * scale,
            unitPriceMinor: unitPriceMinor,
            unitCostMinor: unitCostMinor,
          ),
        ],
      ),
      payments: <PaymentAllocation>[
        PaymentAllocation(
          paymentMethod: method,
          currencyId: currencyId,
          amountMinor: total,
          exchangeRateNumerator: 1,
          exchangeRateDenominator: 1,
          baseAmountMinor: total,
        ),
      ],
      cashSessionId: cashSessionId,
    );
    return result.saleId;
  }

  group('profit and loss', () {
    test('an empty period reports zeros, not nulls', () async {
      final pnl = await reports.profitAndLoss(range);
      expect(pnl.revenueMinor, 0);
      expect(pnl.costOfGoodsMinor, 0);
      expect(pnl.grossProfitMinor, 0);
      expect(pnl.operatingExpensesMinor, 0);
      expect(pnl.netOperatingProfitMinor, 0);
      expect(pnl.invoiceCount, 0);
    });

    test('gross profit is revenue less cost of goods', () async {
      // Two widgets at 150.00, costing 100.00 each: revenue 300.00, cost 200.00.
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );

      final pnl = await reports.profitAndLoss(range);
      expect(pnl.revenueMinor, 30000);
      expect(pnl.costOfGoodsMinor, 20000);
      expect(pnl.grossProfitMinor, 10000);
      expect(pnl.netOperatingProfitMinor, 10000);
      expect(pnl.invoiceCount, 1);
    });

    test('operating expenses reduce net profit but not gross profit', () async {
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );
      await expenses.record(
        description: 'Power',
        amountMinor: 4000,
        currencyId: currencyId,
        paymentMethod: PaymentMethod.cash,
      );

      final pnl = await reports.profitAndLoss(range);
      // Gross profit is untouched by an operating expense.
      expect(pnl.grossProfitMinor, 10000);
      expect(pnl.operatingExpensesMinor, 4000);
      expect(pnl.netOperatingProfitMinor, 6000);
    });

    test('a return reduces revenue and restores cost', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );
      final saleId = await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );
      final sale = await sales.findById(saleId);
      await sales.createReturn(
        saleId: saleId,
        quantityBySaleItem: <int, int>{sale!.lines.single.id!: scale},
        refundCash: true,
        cashSessionId: sessionId,
      );

      final pnl = await reports.profitAndLoss(range);
      // One of two units came back: revenue 150.00, cost 100.00.
      expect(pnl.netRevenueMinor, 15000);
      expect(pnl.netCostOfGoodsMinor, 10000);
      expect(pnl.grossProfitMinor, 5000);
    });

    test('a voided sale is excluded entirely', () async {
      final saleId = await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );
      await sales.voidSale(saleId: saleId, reason: 'mistake');

      final pnl = await reports.profitAndLoss(range);
      expect(pnl.revenueMinor, 0);
      expect(pnl.costOfGoodsMinor, 0);
      expect(pnl.invoiceCount, 0);
    });

    test('the statement lists its lines in order', () async {
      await sell(
        productId: widgetId,
        units: 1,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );
      final table = (await reports.profitAndLoss(range)).toTable();
      final lines = <String>[for (final row in table.rows) row['line']];

      expect(lines.first, startsWith('Revenue'));
      expect(lines.indexOf('Net revenue'),
          lessThan(lines.indexOf('Gross profit')));
      expect(lines.indexOf('Gross profit'),
          lessThan(lines.indexOf('Net operating profit')));
      expect(lines.last, 'Net operating profit');
    });
  });

  group('revenue is not collected cash', () {
    test('a credit sale is revenue but not a payment', () async {
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
        method: PaymentMethod.credit,
        customer: customerId,
      );

      final pnl = await reports.profitAndLoss(range);
      // It is revenue.
      expect(pnl.revenueMinor, 30000);

      // But no money was received.
      final payments = await reports.paymentsByMethod(range);
      expect(payments.rows, isEmpty);
      expect(payments.totals!['amount'], '0.00');
    });

    test('a cash sale appears as a received payment', () async {
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );

      final payments = await reports.paymentsByMethod(range);
      expect(payments.rows, hasLength(1));
      expect(payments.rows.single['method'], 'Cash');
      expect(payments.rows.single['amount'], '300.00');
    });

    test('a later debt collection counts as money received', () async {
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
        method: PaymentMethod.credit,
        customer: customerId,
      );
      await customers.recordPayment(
        customerId: customerId,
        paymentMethod: PaymentMethod.cash,
        currencyId: currencyId,
        amountMinor: 30000,
        exchangeRateNumerator: 1,
        exchangeRateDenominator: 1,
      );

      final payments = await reports.paymentsByMethod(range);
      expect(payments.rows.single['amount'], '300.00');
      // And the debt is cleared.
      expect(await customers.balanceOf(customerId), 0);
    });

    test('a credit sale does not enter the cash drawer', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
        method: PaymentMethod.credit,
        customer: customerId,
        cashSessionId: sessionId,
      );

      final summary = await register.summary(sessionId);
      expect(summary.cashInMinor, 0);
      expect(summary.expectedCashMinor, 0);
    });
  });

  group('sales reports', () {
    test('reports per product with profit', () async {
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );
      await sell(
        productId: gadgetId,
        units: 5,
        unitPriceMinor: 8000,
        unitCostMinor: 5000,
      );

      final table = await reports.salesByProduct(range);
      expect(table.rows, hasLength(2));
      // Gadget revenue (400.00) exceeds Widget (300.00), so Gadget sorts first.
      expect(table.rows.first['product'], 'Gadget');
      expect(table.rows.first['revenue'], '400.00');
      expect(table.rows.first['cost'], '250.00');
      expect(table.rows.first['profit'], '150.00');

      final widget = table.rows.firstWhere((row) => row['product'] == 'Widget');
      expect(widget['revenue'], '300.00');
      expect(widget['profit'], '100.00');

      expect(table.totals!['revenue'], '700.00');
      expect(table.totals!['profit'], '250.00');
    });

    test('reports per customer, separating the outstanding part', () async {
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
        method: PaymentMethod.credit,
        customer: customerId,
      );

      final table = await reports.salesByCustomer(range);
      expect(table.rows.single['customer'], 'Khalid');
      expect(table.rows.single['revenue'], '300.00');
      expect(table.rows.single['outstanding'], '300.00');
    });

    test('groups sales by day', () async {
      await sell(
        productId: widgetId,
        units: 1,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );
      await sell(
        productId: widgetId,
        units: 1,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );

      final table = await reports.salesByPeriod(range, grouping: SalesGrouping.day);
      // Both sales are on the same day, so they fall in one bucket.
      expect(table.rows, hasLength(1));
      expect(table.rows.single['invoices'], '2');
      expect(table.rows.single['revenue'], '300.00');
    });

    test('groups sales by category', () async {
      final categoryId = await db.into(db.categories).insert(
            CategoriesCompanion.insert(
              name: 'Food',
              createdAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      await products.update(id: widgetId, name: 'Widget', categoryId: categoryId);

      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );

      final table = await reports.salesByCategory(range);
      expect(table.rows.single['category'], 'Food');
      expect(table.rows.single['revenue'], '300.00');
    });
  });

  group('purchases and expenses reports', () {
    test('reports purchases per supplier', () async {
      final supplierId = await suppliers.create(name: 'Acme');
      await purchases.post(
        draft: PurchaseDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          supplierId: supplierId,
          lines: <PurchaseLine>[
            PurchaseLine(
              productId: widgetId,
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

      final table = await reports.purchasesBySupplier(range);
      expect(table.rows.single['supplier'], 'Acme');
      expect(table.rows.single['total'], '1000.00');
      expect(table.rows.single['outstanding'], '1000.00');
    });

    test('reports expenses per category', () async {
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
        amountMinor: 20000,
        currencyId: currencyId,
        paymentMethod: PaymentMethod.cash,
        categoryId: power.id,
      );

      final table = await reports.expensesByCategory(range);
      expect(table.rows, hasLength(2));
      expect(table.rows.first['category'], 'Rent');
      expect(table.totals!['total'], '1200.00');
    });
  });

  group('inventory reports', () {
    test('values stock at weighted average cost, not selling price', () async {
      final table = await reports.inventoryValuation();
      expect(table.rows, hasLength(2));
      // 100 widgets at cost 100.00 is 10,000.00, not the 15,000.00 retail value.
      final widget = table.rows.firstWhere((row) => row['product'] == 'Widget');
      expect(widget['cost'], '100.00');
      expect(widget['value'], '10000.00');
      expect(table.totals!['value'], '15000.00');
    });

    test('lists low stock and excludes healthy stock', () async {
      await products.update(id: widgetId, name: 'Widget', minimumStockScaled: 50 * scale);
      await products.update(id: gadgetId, name: 'Gadget', minimumStockScaled: 50 * scale);

      // Sell all but ten widgets.
      await inventory.apply(
        productId: widgetId,
        movementType: MovementType.sale,
        signedQuantityScaled: -90 * scale,
        referenceType: ReferenceType.sale,
        allowNegativeStock: false,
      );

      final table = await reports.lowStock();
      expect(table.rows, hasLength(1));
      expect(table.rows.single['product'], 'Widget');
      expect(table.rows.single['quantity'], '10');
      expect(table.rows.single['minimum'], '50');
    });
  });

  group('debt reports', () {
    test('reports what customers owe', () async {
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
        method: PaymentMethod.credit,
        customer: customerId,
      );

      final table = await reports.customerDebts();
      expect(table.rows.single['customer'], 'Khalid');
      expect(table.rows.single['balance'], '300.00');
      expect(table.totals!['balance'], '300.00');
    });

    test('reports what the store owes suppliers', () async {
      final supplierId = await suppliers.create(name: 'Acme');
      await purchases.post(
        draft: PurchaseDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          supplierId: supplierId,
          lines: <PurchaseLine>[
            PurchaseLine(
              productId: widgetId,
              productName: 'Widget',
              quantityScaled: 5 * scale,
              unitCostMinor: 10000,
            ),
          ],
        ),
        payments: <PurchasePayment>[
          PurchasePayment(
            paymentMethod: PaymentMethod.credit,
            currencyId: currencyId,
            amountMinor: 50000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 50000,
          ),
        ],
      );

      final table = await reports.supplierDebts();
      expect(table.rows.single['supplier'], 'Acme');
      expect(table.rows.single['balance'], '500.00');
    });
  });

  group('cash register report', () {
    test('reports expected, counted and the difference', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 100000,
        currencyId: currencyId,
      );
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
        cashSessionId: sessionId,
      );
      await register.closeSession(
        sessionId: sessionId,
        actualCashMinor: 125000,
      );

      final table = await reports.cashRegisterReport(range);
      expect(table.rows, hasLength(1));
      expect(table.rows.single['expected'], '1300.00');
      expect(table.rows.single['actual'], '1250.00');
      // The drawer was 50.00 short.
      expect(table.rows.single['difference'], '-50.00');
      expect(table.totals!['difference'], '-50.00');
    });
  });

  group('returns report', () {
    test('lists a return against its invoice', () async {
      final sessionId = await register.openSession(
        openingBalanceMinor: 0,
        currencyId: currencyId,
      );
      final saleId = await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );
      final sale = await sales.findById(saleId);
      await sales.createReturn(
        saleId: saleId,
        quantityBySaleItem: <int, int>{sale!.lines.single.id!: scale},
        refundCash: true,
        cashSessionId: sessionId,
      );

      final table = await reports.returnsReport(range);
      expect(table.rows, hasLength(1));
      expect(table.rows.single['invoice'], sale.invoiceNo);
      expect(table.rows.single['total'], '150.00');
    });
  });

  group('CSV export', () {
    test('writes a header, the rows and a total line', () async {
      await sell(
        productId: widgetId,
        units: 2,
        unitPriceMinor: 15000,
        unitCostMinor: 10000,
      );
      final table = await reports.salesByProduct(range);
      final parsed = Csv.parse(table.toCsv());

      expect(parsed.first, <String>[
        'Product',
        'Quantity',
        'Revenue',
        'Cost',
        'Profit',
      ]);
      expect(parsed, hasLength(3)); // header, one row, total
      expect(parsed[1].first, 'Widget');
      expect(parsed.last.first, 'TOTAL');
      expect(parsed.last[2], '300.00');
    });

    test('quotes a field containing a separator', () async {
      final boltId = await products.create(
        name: 'Bolt, 10mm',
        purchaseCostMinor: 100,
        sellingPriceMinor: 200,
      );
      await inventory.apply(
        productId: boltId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 100,
      );
      // The name is not sold, so an inventory report carries it instead.
      final table = await reports.inventoryValuation();
      final csv = table.toCsv();
      expect(csv, contains('"Bolt, 10mm"'));
      // And it round-trips back to one field.
      final parsed = Csv.parse(csv);
      expect(
        parsed.any((row) => row.first == 'Bolt, 10mm'),
        isTrue,
      );
    });

    test('builds a safe file name', () async {
      final table = await reports.salesByProduct(range);
      final name = table.fileName('2026-11-03');
      expect(name, 'sales_by_product_2026-11-03.csv');
    });
  });

  group('dashboard', () {
    test('an empty database produces zeros and empty lists', () async {
      final snapshot = await dashboard.load(DateRange.day(DateTime(2026, 3, 1)));
      expect(snapshot.salesTotal, 0);
      expect(snapshot.invoiceCount, 0);
      expect(snapshot.grossProfit, 0);
      expect(snapshot.netOperatingProfit, 0);
      expect(snapshot.topProducts, isEmpty);
      expect(snapshot.recentTransactions, isEmpty);
    });

    test('matches the known dataset', () async {
      final today = DateTime.now();
      final result = await sales.post(
        draft: SaleDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: widgetId,
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
      expect(result.invoiceNo, isNotEmpty);

      await expenses.record(
        description: 'Power',
        amountMinor: 5000,
        currencyId: currencyId,
        paymentMethod: PaymentMethod.cash,
      );

      final snapshot = await dashboard.load(DateRange.day(today));
      expect(snapshot.salesTotal, 30000);
      expect(snapshot.invoiceCount, 1);
      expect(snapshot.costOfGoodsSold, 20000);
      expect(snapshot.expensesTotal, 5000);
      expect(snapshot.grossProfit, 10000);
      expect(snapshot.netOperatingProfit, 5000);
      expect(snapshot.topProducts.single.name, 'Widget');
      expect(snapshot.recentTransactions, isNotEmpty);
    });

    test('reports the inventory value and low stock count', () async {
      await products.update(id: widgetId, name: 'Widget', minimumStockScaled: 50 * scale);
      final snapshot = await dashboard.load(DateRange.day(DateTime.now()));
      // 100 widgets at 100.00 plus 100 gadgets at 50.00.
      expect(snapshot.inventoryValue, 1500000);
      expect(snapshot.lowStockCount, greaterThanOrEqualTo(0));
    });
  });
}
