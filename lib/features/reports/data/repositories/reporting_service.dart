import 'package:drift/drift.dart';

import '../../../../core/constants/enums.dart';
import '../../../../core/money/money.dart';
import '../../../../core/money/quantity.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../infrastructure/database/app_database.dart';
import '../../../dashboard/domain/entities/dashboard_period.dart';
import '../../domain/entities/report_table.dart';

/// Builds the business reports.
///
/// ## Revenue is not cash
///
/// A posted invoice is revenue whether or not it has been paid. A credit sale
/// therefore appears in the sales reports but contributes nothing to collected
/// cash, and the payment-method report counts only tenders that were actually
/// received. The two are never added together, because a shopkeeper who mistakes
/// revenue for money in the till will spend money that is not there.
///
/// Every amount is taken from the `base_*` columns written when the document was
/// posted, so a later change to a configured rate cannot rewrite a past report.
class ReportingService {
  const ReportingService(this._db);

  final AppDatabase _db;

  // ---------------------------------------------------------------------------
  // Sales
  // ---------------------------------------------------------------------------

  /// Sales over a period, grouped by day, week or month.
  Future<ReportTable> salesByPeriod(
    DateRange range, {
    SalesGrouping grouping = SalesGrouping.day,
  }) async {
    final base = await _baseCurrency();
    final rows = await (_db.select(_db.sales)
          ..where((t) =>
              t.status.equals(DocumentStatus.posted.wireValue) &
              t.createdAt.isBiggerOrEqualValue(toStorageTimestamp(range.start)) &
              t.createdAt
                  .isSmallerThanValue(toStorageTimestamp(range.endExclusive)))
          ..orderBy(<OrderClauseGenerator<$SalesTable>>[
            (t) => OrderingTerm(expression: t.createdAt),
          ]))
        .get();

    final buckets = <String, ({int revenue, int cost, int count})>{};
    for (final row in rows) {
      final key = _bucketKey(row.createdAt, grouping);
      final existing = buckets[key] ?? (revenue: 0, cost: 0, count: 0);
      buckets[key] = (
        revenue: existing.revenue + row.baseTotal,
        cost: existing.cost + row.baseCostTotal,
        count: existing.count + 1,
      );
    }

    final keys = buckets.keys.toList()..sort();
    var totalRevenue = 0;
    var totalCost = 0;
    var totalCount = 0;
    final reportRows = <ReportRow>[];
    for (final key in keys) {
      final bucket = buckets[key]!;
      totalRevenue += bucket.revenue;
      totalCost += bucket.cost;
      totalCount += bucket.count;
      reportRows.add(
        ReportRow(<String, String>{
          'period': key,
          'invoices': '${bucket.count}',
          'revenue': _money(bucket.revenue, base.decimalDigits),
          'cost': _money(bucket.cost, base.decimalDigits),
          'profit': _money(bucket.revenue - bucket.cost, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Sales by ${grouping.label}',
      currencyCode: base.code,
      note: 'Revenue is invoiced value. It is not cash collected.',
      columns: const <ReportColumn>[
        ReportColumn(key: 'period', label: 'Period'),
        ReportColumn(key: 'invoices', label: 'Invoices', numeric: true),
        ReportColumn(key: 'revenue', label: 'Revenue', numeric: true),
        ReportColumn(key: 'cost', label: 'Cost of goods', numeric: true),
        ReportColumn(key: 'profit', label: 'Gross profit', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'period': '',
        'invoices': '$totalCount',
        'revenue': _money(totalRevenue, base.decimalDigits),
        'cost': _money(totalCost, base.decimalDigits),
        'profit': _money(totalRevenue - totalCost, base.decimalDigits),
      }),
    );
  }

  /// Revenue, cost and profit per product.
  Future<ReportTable> salesByProduct(DateRange range) async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT i.product_name_snapshot AS name,
             SUM(i.quantity_scaled) AS quantity_scaled,
             SUM(CASE WHEN s.exchange_rate_denominator = 0 THEN i.total
                      ELSE i.total * s.exchange_rate_numerator
                           / s.exchange_rate_denominator END) AS revenue,
             SUM(CASE WHEN s.exchange_rate_denominator = 0 THEN i.total
                      ELSE i.unit_cost * i.quantity_scaled / 1000
                           * s.exchange_rate_numerator
                           / s.exchange_rate_denominator END) AS cost
      FROM sale_items i
      JOIN sales s ON s.id = i.sale_id
      WHERE s.status = 'posted'
        AND s.created_at >= :from AND s.created_at < :to
      GROUP BY i.product_name_snapshot
      ORDER BY revenue DESC
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.saleItems,
        _db.sales,
      },
    ).get();

    var totalRevenue = 0;
    var totalCost = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final revenue = row.read<int>('revenue');
      final cost = row.read<int>('cost');
      totalRevenue += revenue;
      totalCost += cost;
      reportRows.add(
        ReportRow(<String, String>{
          'product': row.read<String>('name'),
          'quantity': Quantity(row.read<int>('quantity_scaled')).toDisplayString(),
          'revenue': _money(revenue, base.decimalDigits),
          'cost': _money(cost, base.decimalDigits),
          'profit': _money(revenue - cost, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Sales by product',
      currencyCode: base.code,
      columns: const <ReportColumn>[
        ReportColumn(key: 'product', label: 'Product'),
        ReportColumn(key: 'quantity', label: 'Quantity', numeric: true),
        ReportColumn(key: 'revenue', label: 'Revenue', numeric: true),
        ReportColumn(key: 'cost', label: 'Cost', numeric: true),
        ReportColumn(key: 'profit', label: 'Profit', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'product': '',
        'quantity': '',
        'revenue': _money(totalRevenue, base.decimalDigits),
        'cost': _money(totalCost, base.decimalDigits),
        'profit': _money(totalRevenue - totalCost, base.decimalDigits),
      }),
    );
  }

  /// Revenue per category, resolved through each product's current category.
  Future<ReportTable> salesByCategory(DateRange range) async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT COALESCE(c.name, 'Uncategorised') AS name,
             SUM(i.quantity_scaled) AS quantity_scaled,
             SUM(CASE WHEN s.exchange_rate_denominator = 0 THEN i.total
                      ELSE i.total * s.exchange_rate_numerator
                           / s.exchange_rate_denominator END) AS revenue
      FROM sale_items i
      JOIN sales s ON s.id = i.sale_id
      LEFT JOIN products p ON p.id = i.product_id
      LEFT JOIN categories c ON c.id = p.category_id
      WHERE s.status = 'posted'
        AND s.created_at >= :from AND s.created_at < :to
      GROUP BY COALESCE(c.name, 'Uncategorised')
      ORDER BY revenue DESC
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.saleItems,
        _db.sales,
        _db.products,
        _db.categories,
      },
    ).get();

    var total = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final revenue = row.read<int>('revenue');
      total += revenue;
      reportRows.add(
        ReportRow(<String, String>{
          'category': row.read<String>('name'),
          'quantity':
              Quantity(row.read<int>('quantity_scaled')).toDisplayString(),
          'revenue': _money(revenue, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Sales by category',
      currencyCode: base.code,
      columns: const <ReportColumn>[
        ReportColumn(key: 'category', label: 'Category'),
        ReportColumn(key: 'quantity', label: 'Quantity', numeric: true),
        ReportColumn(key: 'revenue', label: 'Revenue', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'category': '',
        'quantity': '',
        'revenue': _money(total, base.decimalDigits),
      }),
    );
  }

  /// Sales per customer, with the outstanding balance on those invoices.
  Future<ReportTable> salesByCustomer(DateRange range) async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT COALESCE(c.name, 'Walk-in') AS name,
             COUNT(s.id) AS invoices,
             SUM(s.base_total) AS revenue,
             SUM(s.base_total - s.base_paid_amount) AS outstanding
      FROM sales s
      LEFT JOIN customers c ON c.id = s.customer_id
      WHERE s.status = 'posted'
        AND s.created_at >= :from AND s.created_at < :to
      GROUP BY COALESCE(c.name, 'Walk-in')
      ORDER BY revenue DESC
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.sales, _db.customers},
    ).get();

    var totalRevenue = 0;
    var totalOutstanding = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final revenue = row.read<int>('revenue');
      final outstanding = row.read<int>('outstanding');
      totalRevenue += revenue;
      totalOutstanding += outstanding;
      reportRows.add(
        ReportRow(<String, String>{
          'customer': row.read<String>('name'),
          'invoices': '${row.read<int>('invoices')}',
          'revenue': _money(revenue, base.decimalDigits),
          'outstanding': _money(outstanding, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Sales by customer',
      currencyCode: base.code,
      note: 'Outstanding is the unpaid part of these invoices, not cash owed '
          'outside this period.',
      columns: const <ReportColumn>[
        ReportColumn(key: 'customer', label: 'Customer'),
        ReportColumn(key: 'invoices', label: 'Invoices', numeric: true),
        ReportColumn(key: 'revenue', label: 'Revenue', numeric: true),
        ReportColumn(key: 'outstanding', label: 'Outstanding', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'customer': '',
        'invoices': '',
        'revenue': _money(totalRevenue, base.decimalDigits),
        'outstanding': _money(totalOutstanding, base.decimalDigits),
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // Purchases, expenses and profit
  // ---------------------------------------------------------------------------

  /// Purchases per supplier over a period.
  Future<ReportTable> purchasesBySupplier(DateRange range) async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT COALESCE(s.name, 'No supplier') AS name,
             COUNT(p.id) AS invoices,
             SUM(p.base_total) AS total,
             SUM(p.base_total - p.base_paid_amount) AS outstanding
      FROM purchases p
      LEFT JOIN suppliers s ON s.id = p.supplier_id
      WHERE p.status = 'posted'
        AND p.created_at >= :from AND p.created_at < :to
      GROUP BY COALESCE(s.name, 'No supplier')
      ORDER BY total DESC
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.purchases,
        _db.suppliers,
      },
    ).get();

    var total = 0;
    var totalOutstanding = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final amount = row.read<int>('total');
      final outstanding = row.read<int>('outstanding');
      total += amount;
      totalOutstanding += outstanding;
      reportRows.add(
        ReportRow(<String, String>{
          'supplier': row.read<String>('name'),
          'invoices': '${row.read<int>('invoices')}',
          'total': _money(amount, base.decimalDigits),
          'outstanding': _money(outstanding, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Purchases by supplier',
      currencyCode: base.code,
      columns: const <ReportColumn>[
        ReportColumn(key: 'supplier', label: 'Supplier'),
        ReportColumn(key: 'invoices', label: 'Invoices', numeric: true),
        ReportColumn(key: 'total', label: 'Total', numeric: true),
        ReportColumn(key: 'outstanding', label: 'Outstanding', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'supplier': '',
        'invoices': '',
        'total': _money(total, base.decimalDigits),
        'outstanding': _money(totalOutstanding, base.decimalDigits),
      }),
    );
  }

  /// Expenses per category over a period.
  Future<ReportTable> expensesByCategory(DateRange range) async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT COALESCE(c.name, 'Uncategorised') AS name,
             COUNT(e.id) AS entries,
             SUM(e.base_amount) AS total
      FROM expenses e
      LEFT JOIN expense_categories c ON c.id = e.category_id
      WHERE e.created_at >= :from AND e.created_at < :to
      GROUP BY COALESCE(c.name, 'Uncategorised')
      ORDER BY total DESC
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.expenses,
        _db.expenseCategories,
      },
    ).get();

    var total = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final amount = row.read<int>('total');
      total += amount;
      reportRows.add(
        ReportRow(<String, String>{
          'category': row.read<String>('name'),
          'entries': '${row.read<int>('entries')}',
          'total': _money(amount, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Expenses by category',
      currencyCode: base.code,
      columns: const <ReportColumn>[
        ReportColumn(key: 'category', label: 'Category'),
        ReportColumn(key: 'entries', label: 'Entries', numeric: true),
        ReportColumn(key: 'total', label: 'Total', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'category': '',
        'entries': '',
        'total': _money(total, base.decimalDigits),
      }),
    );
  }

  /// The profit and loss statement for a period.
  ///
  /// Kept as a statement rather than a table of rows because the sequence matters:
  /// revenue less cost of goods gives gross profit, and gross profit less
  /// operating expenses gives net operating profit. Presenting them out of order
  /// invites reading a subtotal as a final figure.
  Future<ProfitAndLoss> profitAndLoss(DateRange range) async {
    final base = await _baseCurrency();
    final salesTotals = await _db.customSelect(
      '''
      SELECT COALESCE(SUM(base_total), 0) AS revenue,
             COALESCE(SUM(base_cost_total), 0) AS cost,
             COUNT(*) AS invoices
      FROM sales
      WHERE status = 'posted' AND created_at >= :from AND created_at < :to
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.sales},
    ).getSingle();

    final expenseTotal = await _db.customSelect(
      '''
      SELECT COALESCE(SUM(base_amount), 0) AS total
      FROM expenses
      WHERE created_at >= :from AND created_at < :to
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.expenses},
    ).getSingle();

    // Returns reduce revenue and restore cost, so both are subtracted.
    final returnTotals = await _db.customSelect(
      '''
      SELECT COALESCE(SUM(
               CASE WHEN r.exchange_rate_denominator = 0 THEN r.total
                    ELSE r.total * r.exchange_rate_numerator
                         / r.exchange_rate_denominator END), 0) AS revenue,
             COALESCE(SUM(
               CASE WHEN r.exchange_rate_denominator = 0 THEN r.cost_total
                    ELSE r.cost_total * r.exchange_rate_numerator
                         / r.exchange_rate_denominator END), 0) AS cost
      FROM sales_returns r
      WHERE r.status = 'posted' AND r.created_at >= :from AND r.created_at < :to
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.salesReturns},
    ).getSingle();

    return ProfitAndLoss(
      baseCurrencyCode: base.code,
      decimalDigits: base.decimalDigits,
      revenueMinor: salesTotals.read<int>('revenue'),
      returnsMinor: returnTotals.read<int>('revenue'),
      costOfGoodsMinor: salesTotals.read<int>('cost'),
      returnsCostMinor: returnTotals.read<int>('cost'),
      operatingExpensesMinor: expenseTotal.read<int>('total'),
      invoiceCount: salesTotals.read<int>('invoices'),
    );
  }

  // ---------------------------------------------------------------------------
  // Inventory
  // ---------------------------------------------------------------------------

  /// The value of stock on hand, per product.
  Future<ReportTable> inventoryValuation() async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT p.name AS name,
             p.sku AS sku,
             st.quantity_scaled AS quantity_scaled,
             st.average_cost AS average_cost,
             st.quantity_scaled * st.average_cost / 1000 AS value
      FROM product_stock st
      JOIN products p ON p.id = st.product_id
      WHERE st.quantity_scaled <> 0
      ORDER BY value DESC
      ''',
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.productStock,
        _db.products,
      },
    ).get();

    var total = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final value = row.read<int>('value');
      total += value;
      reportRows.add(
        ReportRow(<String, String>{
          'product': row.read<String>('name'),
          'sku': row.read<String?>('sku') ?? '',
          'quantity':
              Quantity(row.read<int>('quantity_scaled')).toDisplayString(),
          'cost': _money(row.read<int>('average_cost'), base.decimalDigits),
          'value': _money(value, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Inventory valuation',
      currencyCode: base.code,
      note: 'Valued at weighted average cost, not at selling price.',
      columns: const <ReportColumn>[
        ReportColumn(key: 'product', label: 'Product'),
        ReportColumn(key: 'sku', label: 'SKU'),
        ReportColumn(key: 'quantity', label: 'Quantity', numeric: true),
        ReportColumn(key: 'cost', label: 'Unit cost', numeric: true),
        ReportColumn(key: 'value', label: 'Value', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'product': '',
        'sku': '',
        'quantity': '',
        'cost': '',
        'value': _money(total, base.decimalDigits),
      }),
    );
  }

  /// Products at or below their minimum stock.
  Future<ReportTable> lowStock() async {
    final rows = await _db.customSelect(
      '''
      SELECT p.name AS name, p.sku AS sku,
             st.quantity_scaled AS quantity_scaled,
             p.minimum_stock AS minimum_scaled
      FROM products p
      LEFT JOIN product_stock st ON st.product_id = p.id
      WHERE p.is_active = 1
        AND COALESCE(st.quantity_scaled, 0) <= p.minimum_stock
        AND p.minimum_stock > 0
      ORDER BY (COALESCE(st.quantity_scaled, 0) - p.minimum_stock)
      ''',
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.products,
        _db.productStock,
      },
    ).get();

    return ReportTable(
      title: 'Low stock',
      note: 'Products at or below their minimum stock level.',
      columns: const <ReportColumn>[
        ReportColumn(key: 'product', label: 'Product'),
        ReportColumn(key: 'sku', label: 'SKU'),
        ReportColumn(key: 'quantity', label: 'On hand', numeric: true),
        ReportColumn(key: 'minimum', label: 'Minimum', numeric: true),
      ],
      rows: <ReportRow>[
        for (final row in rows)
          ReportRow(<String, String>{
            'product': row.read<String>('name'),
            'sku': row.read<String?>('sku') ?? '',
            'quantity': Quantity(row.read<int>('quantity_scaled'))
                .toDisplayString(),
            'minimum':
                Quantity(row.read<int>('minimum_scaled')).toDisplayString(),
          }),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Debts
  // ---------------------------------------------------------------------------

  /// What customers owe.
  Future<ReportTable> customerDebts() async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT c.name AS name,
             SUM(CASE WHEN e.direction = 'debit' THEN e.amount_minor
                      ELSE -e.amount_minor END) AS balance
      FROM customer_account_entries e
      JOIN customers c ON c.id = e.customer_id
      GROUP BY c.id
      HAVING balance <> 0
      ORDER BY balance DESC
      ''',
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.customerAccountEntries,
        _db.customers,
      },
    ).get();

    var total = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final balance = row.read<int>('balance');
      if (balance > 0) total += balance;
      reportRows.add(
        ReportRow(<String, String>{
          'customer': row.read<String>('name'),
          'balance': _money(balance, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Customer debts',
      currencyCode: base.code,
      note: 'Positive is owed to the store. A negative balance means the customer '
          'is in credit.',
      columns: const <ReportColumn>[
        ReportColumn(key: 'customer', label: 'Customer'),
        ReportColumn(key: 'balance', label: 'Balance', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'customer': '',
        'balance': _money(total, base.decimalDigits),
      }),
    );
  }

  /// What the store owes suppliers.
  Future<ReportTable> supplierDebts() async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT s.name AS name,
             SUM(CASE WHEN e.direction = 'credit' THEN e.amount_minor
                      ELSE -e.amount_minor END) AS balance
      FROM supplier_account_entries e
      JOIN suppliers s ON s.id = e.supplier_id
      GROUP BY s.id
      HAVING balance <> 0
      ORDER BY balance DESC
      ''',
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.supplierAccountEntries,
        _db.suppliers,
      },
    ).get();

    var total = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final balance = row.read<int>('balance');
      if (balance > 0) total += balance;
      reportRows.add(
        ReportRow(<String, String>{
          'supplier': row.read<String>('name'),
          'balance': _money(balance, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Supplier debts',
      currencyCode: base.code,
      note: 'Positive is owed by the store to the supplier.',
      columns: const <ReportColumn>[
        ReportColumn(key: 'supplier', label: 'Supplier'),
        ReportColumn(key: 'balance', label: 'Balance', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'supplier': '',
        'balance': _money(total, base.decimalDigits),
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // Payments and returns
  // ---------------------------------------------------------------------------

  /// Money actually received, by payment method.
  ///
  /// This counts tenders, not invoices. A credit sale contributes nothing here,
  /// which is exactly the distinction that keeps collected cash separate from
  /// revenue.
  Future<ReportTable> paymentsByMethod(DateRange range) async {
    final base = await _baseCurrency();

    final saleRows = await _db.customSelect(
      '''
      SELECT sp.payment_method AS method,
             SUM(sp.base_amount) AS amount,
             COUNT(*) AS entries
      FROM sale_payments sp
      JOIN sales s ON s.id = sp.sale_id
      WHERE s.status = 'posted'
        AND sp.payment_method <> 'credit'
        AND sp.created_at >= :from AND sp.created_at < :to
      GROUP BY sp.payment_method
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.salePayments,
        _db.sales,
      },
    ).get();

    final collectionRows = await _db.customSelect(
      '''
      SELECT cp.payment_method AS method,
             SUM(cp.base_amount) AS amount,
             COUNT(*) AS entries
      FROM customer_payments cp
      WHERE cp.payment_method <> 'credit'
        AND cp.created_at >= :from AND cp.created_at < :to
      GROUP BY cp.payment_method
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.customerPayments,
      },
    ).get();

    // Sale tenders and later debt collections are both money received, so they
    // are combined per method rather than listed twice.
    final byMethod = <String, ({int amount, int entries})>{};
    for (final row in <QueryRow>[...saleRows, ...collectionRows]) {
      final method = row.read<String>('method');
      final existing = byMethod[method] ?? (amount: 0, entries: 0);
      byMethod[method] = (
        amount: existing.amount + row.read<int>('amount'),
        entries: existing.entries + row.read<int>('entries'),
      );
    }

    var total = 0;
    final reportRows = <ReportRow>[];
    final methods = byMethod.keys.toList()
      ..sort((a, b) => byMethod[b]!.amount.compareTo(byMethod[a]!.amount));
    for (final method in methods) {
      final entry = byMethod[method]!;
      total += entry.amount;
      reportRows.add(
        ReportRow(<String, String>{
          'method': _methodLabel(method),
          'entries': '${entry.entries}',
          'amount': _money(entry.amount, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Payments by method',
      currencyCode: base.code,
      note: 'Money received, including later debt collections. Credit sales are '
          'excluded because no money was received.',
      columns: const <ReportColumn>[
        ReportColumn(key: 'method', label: 'Method'),
        ReportColumn(key: 'entries', label: 'Entries', numeric: true),
        ReportColumn(key: 'amount', label: 'Received', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'method': '',
        'entries': '',
        'amount': _money(total, base.decimalDigits),
      }),
    );
  }

  /// Returns to customers over a period.
  Future<ReportTable> returnsReport(DateRange range) async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT r.return_no AS return_no,
             s.invoice_no AS invoice_no,
             CASE WHEN r.exchange_rate_denominator = 0 THEN r.total
                  ELSE r.total * r.exchange_rate_numerator
                       / r.exchange_rate_denominator END AS total,
             r.created_at AS created_at
      FROM sales_returns r
      JOIN sales s ON s.id = r.sale_id
      WHERE r.status = 'posted'
        AND r.created_at >= :from AND r.created_at < :to
      ORDER BY r.created_at DESC
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{
        _db.salesReturns,
        _db.sales,
      },
    ).get();

    var total = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final amount = row.read<int>('total');
      total += amount;
      reportRows.add(
        ReportRow(<String, String>{
          'return': row.read<String>('return_no'),
          'invoice': row.read<String>('invoice_no'),
          'date': row.read<String>('created_at').split('T').first,
          'total': _money(amount, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Returns',
      currencyCode: base.code,
      columns: const <ReportColumn>[
        ReportColumn(key: 'return', label: 'Return no.'),
        ReportColumn(key: 'invoice', label: 'Invoice'),
        ReportColumn(key: 'date', label: 'Date'),
        ReportColumn(key: 'total', label: 'Total', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'return': '',
        'invoice': '',
        'date': '',
        'total': _money(total, base.decimalDigits),
      }),
    );
  }

  /// The cash session report for a period.
  Future<ReportTable> cashRegisterReport(DateRange range) async {
    final base = await _baseCurrency();
    final rows = await _db.customSelect(
      '''
      SELECT cs.id AS id, cs.opened_at AS opened_at, cs.closed_at AS closed_at,
             cs.opening_balance AS opening,
             COALESCE(cs.expected_cash, 0) AS expected,
             COALESCE(cs.actual_cash, 0) AS actual,
             COALESCE(cs.difference, 0) AS difference
      FROM cash_sessions cs
      WHERE cs.opened_at >= :from AND cs.opened_at < :to
      ORDER BY cs.opened_at DESC
      ''',
      variables: <Variable<Object>>[
        Variable<String>(toStorageTimestamp(range.start)),
        Variable<String>(toStorageTimestamp(range.endExclusive)),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{_db.cashSessions},
    ).get();

    var totalDifference = 0;
    final reportRows = <ReportRow>[];
    for (final row in rows) {
      final difference = row.read<int>('difference');
      totalDifference += difference;
      reportRows.add(
        ReportRow(<String, String>{
          'session': '#${row.read<int>('id')}',
          'opened': row.read<String>('opened_at').split('T').first,
          'closed': row.read<String?>('closed_at')?.split('T').first ?? 'Open',
          'expected': _money(row.read<int>('expected'), base.decimalDigits),
          'actual': _money(row.read<int>('actual'), base.decimalDigits),
          'difference': _money(difference, base.decimalDigits),
        }),
      );
    }

    return ReportTable(
      title: 'Cash register',
      currencyCode: base.code,
      note: 'A negative difference means the drawer was short.',
      columns: const <ReportColumn>[
        ReportColumn(key: 'session', label: 'Session'),
        ReportColumn(key: 'opened', label: 'Opened'),
        ReportColumn(key: 'closed', label: 'Closed'),
        ReportColumn(key: 'expected', label: 'Expected', numeric: true),
        ReportColumn(key: 'actual', label: 'Counted', numeric: true),
        ReportColumn(key: 'difference', label: 'Difference', numeric: true),
      ],
      rows: reportRows,
      totals: ReportRow(<String, String>{
        'session': '',
        'opened': '',
        'closed': '',
        'expected': '',
        'actual': '',
        'difference': _money(totalDifference, base.decimalDigits),
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<({int id, String code, int decimalDigits})> _baseCurrency() async {
    final row = await (_db.select(_db.currencies)
          ..where((t) => t.isBase.equals(true))
          ..limit(1))
        .getSingleOrNull();
    if (row == null) {
      return (id: 0, code: '', decimalDigits: 2);
    }
    return (id: row.id, code: row.code, decimalDigits: row.decimalDigits);
  }

  String _money(int minorUnits, int digits) =>
      Money(minorUnits, decimalDigits: digits).toDecimalString();

  /// The bucket key a timestamp falls into for a grouping.
  ///
  /// The timestamp is stored in UTC and converted to local time first, so a sale
  /// at 01:00 local time on the first of the month is reported in that month
  /// rather than the previous one.
  String _bucketKey(String storageTimestamp, SalesGrouping grouping) {
    final local = DateTime.parse(storageTimestamp).toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    switch (grouping) {
      case SalesGrouping.day:
        return '${local.year}-$month-$day';
      case SalesGrouping.week:
        // ISO week, computed from the Thursday of the week.
        final thursday = local.add(Duration(days: 4 - _isoWeekday(local)));
        final firstThursday = DateTime(thursday.year, 1, 4);
        final week = 1 +
            (thursday.difference(
                      firstThursday.subtract(
                        Duration(days: _isoWeekday(firstThursday) - 1),
                      ),
                    ).inDays /
                    7)
                .floor();
        return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
      case SalesGrouping.month:
        return '${local.year}-$month';
    }
  }

  static int _isoWeekday(DateTime date) => date.weekday;

  static String _methodLabel(String wireValue) {
    final method = PaymentMethod.fromWire(wireValue);
    return switch (method) {
      PaymentMethod.cash => 'Cash',
      PaymentMethod.bankTransfer => 'Bank transfer',
      PaymentMethod.electronic => 'Electronic',
      PaymentMethod.credit => 'Credit',
    };
  }
}

/// How sales are grouped in the sales-by-period report.
enum SalesGrouping {
  day('day'),
  week('week'),
  month('month');

  const SalesGrouping(this.label);

  final String label;
}

/// The profit and loss statement for a period.
///
/// All amounts are in base-currency minor units.
class ProfitAndLoss {
  const ProfitAndLoss({
    required this.baseCurrencyCode,
    required this.decimalDigits,
    required this.revenueMinor,
    required this.returnsMinor,
    required this.costOfGoodsMinor,
    required this.returnsCostMinor,
    required this.operatingExpensesMinor,
    required this.invoiceCount,
  });

  final String baseCurrencyCode;
  final int decimalDigits;

  /// Invoiced value of posted sales.
  final int revenueMinor;

  /// Value of goods returned by customers, which reduces revenue.
  final int returnsMinor;

  /// Cost of the goods sold.
  final int costOfGoodsMinor;

  /// Cost of the goods returned, which restores cost.
  final int returnsCostMinor;

  /// Operating expenses, which are not part of cost of goods.
  final int operatingExpensesMinor;

  final int invoiceCount;

  /// Revenue after returns.
  int get netRevenueMinor => revenueMinor - returnsMinor;

  /// Cost after the cost of returned goods is restored.
  int get netCostOfGoodsMinor => costOfGoodsMinor - returnsCostMinor;

  /// Revenue after returns, less the cost of the goods sold.
  int get grossProfitMinor => netRevenueMinor - netCostOfGoodsMinor;

  /// Gross profit less operating expenses.
  int get netOperatingProfitMinor =>
      grossProfitMinor - operatingExpensesMinor;

  Money get netRevenue =>
      Money(netRevenueMinor, decimalDigits: decimalDigits);
  Money get costOfGoods =>
      Money(netCostOfGoodsMinor, decimalDigits: decimalDigits);
  Money get grossProfit =>
      Money(grossProfitMinor, decimalDigits: decimalDigits);
  Money get operatingExpenses =>
      Money(operatingExpensesMinor, decimalDigits: decimalDigits);
  Money get netOperatingProfit =>
      Money(netOperatingProfitMinor, decimalDigits: decimalDigits);

  /// The statement as an ordered table, so the subtotals are read in order.
  ReportTable toTable() {
    return ReportTable(
      title: 'Profit and loss',
      currencyCode: baseCurrencyCode,
      note: 'Revenue is invoiced value, not cash collected. Expenses are '
          'operating costs, separate from the cost of goods sold.',
      columns: const <ReportColumn>[
        ReportColumn(key: 'line', label: 'Line'),
        ReportColumn(key: 'amount', label: 'Amount', numeric: true),
      ],
      rows: <ReportRow>[
        ReportRow(<String, String>{
          'line': 'Revenue (invoices: $invoiceCount)',
          'amount': Money(revenueMinor, decimalDigits: decimalDigits)
              .toDecimalString(),
        }),
        ReportRow(<String, String>{
          'line': 'Less returns',
          'amount': Money(returnsMinor, decimalDigits: decimalDigits)
              .toDecimalString(),
        }),
        ReportRow(<String, String>{
          'line': 'Net revenue',
          'amount': netRevenue.toDecimalString(),
        }),
        ReportRow(<String, String>{
          'line': 'Cost of goods sold',
          'amount': Money(costOfGoodsMinor, decimalDigits: decimalDigits)
              .toDecimalString(),
        }),
        ReportRow(<String, String>{
          'line': 'Less cost of returned goods',
          'amount': Money(returnsCostMinor, decimalDigits: decimalDigits)
              .toDecimalString(),
        }),
        ReportRow(<String, String>{
          'line': 'Gross profit',
          'amount': grossProfit.toDecimalString(),
        }),
        ReportRow(<String, String>{
          'line': 'Operating expenses',
          'amount': operatingExpenses.toDecimalString(),
        }),
        ReportRow(<String, String>{
          'line': 'Net operating profit',
          'amount': netOperatingProfit.toDecimalString(),
        }),
      ],
    );
  }
}
