import 'package:drift/drift.dart';

import '../../../core/money/quantity.dart';
import '../../../core/money/rounding.dart';
import '../../../core/utils/timestamps.dart';
import '../../../infrastructure/database/app_database.dart';
import '../domain/entities/dashboard_period.dart';
import '../domain/entities/dashboard_snapshot.dart';

/// Reads dashboard figures from the database.
///
/// Every value is an aggregate over posted records. There are no constants and
/// no fallback numbers: an empty database produces zeros and empty lists.
///
/// ## Multi-currency note
///
/// Revenue, purchases and expenses are summed from the `base_*` columns that
/// were written when each document was posted, so a later change to a
/// configured exchange rate cannot rewrite history. Per-product ranking reads
/// the invoice-currency line totals and converts them with the rate stored on
/// the parent invoice, rounding once with `mulDivRound` in Dart rather than
/// relying on SQLite's truncating integer division.
class DashboardRepository {
  const DashboardRepository(this._db);

  final AppDatabase _db;

  /// Builds the complete snapshot for [range].
  Future<DashboardSnapshot> load(DateRange range) async {
    final base = await _baseCurrency();
    final sales = await _salesTotals(range);
    final purchases = await _purchasesTotal(range);
    final expenses = await _expensesTotal(range);

    return DashboardSnapshot(
      period: range,
      baseCurrencyId: base.id,
      baseCurrencyDecimalDigits: base.decimalDigits,
      salesTotal: sales.revenue,
      invoiceCount: sales.count,
      purchasesTotal: purchases,
      expensesTotal: expenses,
      costOfGoodsSold: sales.cost,
      inventoryValue: await _inventoryValue(),
      lowStockCount: await _lowStockCount(),
      customerDebt: await _customerDebt(),
      supplierDebt: await _supplierDebt(),
      topProducts: await _topProducts(range),
      salesTrend: await _salesTrend(range),
      recentTransactions: await _recentTransactions(),
    );
  }

  Future<({int id, int decimalDigits})> _baseCurrency() async {
    final row = await (_db.select(_db.currencies)
          ..where((t) => t.isBase.equals(true))
          ..limit(1))
        .getSingleOrNull();
    if (row != null) {
      return (id: row.id, decimalDigits: row.decimalDigits);
    }
    // Defensive: seeding always creates a base currency, but if a database was
    // tampered with we fall back to the lowest id so the dashboard still opens
    // rather than crashing.
    final any = await (_db.select(_db.currencies)
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(1))
        .getSingleOrNull();
    if (any == null) {
      throw StateError('No currency is configured in the database');
    }
    return (id: any.id, decimalDigits: any.decimalDigits);
  }

  /// Posted sales revenue, invoice count and cost of goods sold for the period.
  Future<({int revenue, int count, int cost})> _salesTotals(DateRange range) async {
    final rows = await _db.customSelect(
      '''
      SELECT
        COUNT(*)                        AS invoice_count,
        COALESCE(SUM(base_total), 0)    AS revenue,
        COALESCE(SUM(base_cost_total), 0) AS cost
      FROM sales
      WHERE status = 'posted'
        AND created_at >= ?1
        AND created_at < ?2
      ''',
      variables: [
        Variable<String>(range.startStorage),
        Variable<String>(range.endStorage),
      ],
    ).getSingle();
    return (
      revenue: rows.read<int>('revenue'),
      count: rows.read<int>('invoice_count'),
      cost: rows.read<int>('cost'),
    );
  }

  Future<int> _purchasesTotal(DateRange range) async {
    final row = await _db.customSelect(
      '''
      SELECT COALESCE(SUM(base_total), 0) AS total
      FROM purchases
      WHERE status = 'posted'
        AND created_at >= ?1
        AND created_at < ?2
      ''',
      variables: [
        Variable<String>(range.startStorage),
        Variable<String>(range.endStorage),
      ],
    ).getSingle();
    return row.read<int>('total');
  }

  Future<int> _expensesTotal(DateRange range) async {
    final row = await _db.customSelect(
      '''
      SELECT COALESCE(SUM(base_amount), 0) AS total
      FROM expenses
      WHERE created_at >= ?1
        AND created_at < ?2
      ''',
      variables: [
        Variable<String>(range.startStorage),
        Variable<String>(range.endStorage),
      ],
    ).getSingle();
    return row.read<int>('total');
  }

  /// Current inventory value at weighted-average cost.
  ///
  /// The scaled quantity and the minor-unit average cost are multiplied as
  /// integers and reduced once by the quantity scale, so no `double` is used.
  Future<int> _inventoryValue() async {
    final row = await _db.customSelect(
      '''
      SELECT COALESCE(SUM(CAST(quantity_scaled AS INTEGER) * CAST(average_cost AS INTEGER)), 0) AS scaled_product
      FROM product_stock
      WHERE quantity_scaled > 0
      ''',
    ).getSingle();
    final scaledProduct = row.read<int>('scaled_product');
    return divRound(scaledProduct, Quantity.scale);
  }

  Future<int> _lowStockCount() async {
    final row = await _db.customSelect(
      '''
      SELECT COUNT(*) AS low_count
      FROM products p
      JOIN product_stock s ON s.product_id = p.id
      WHERE p.is_active = 1
        AND s.quantity_scaled <= p.minimum_stock
      ''',
    ).getSingle();
    return row.read<int>('low_count');
  }

  /// Outstanding customer receivables, summed from the account ledger.
  Future<int> _customerDebt() async {
    final row = await _db.customSelect(
      '''
      SELECT COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor ELSE -amount_minor END), 0) AS balance
      FROM customer_account_entries
      ''',
    ).getSingle();
    return row.read<int>('balance');
  }

  /// Outstanding supplier payables, summed from the account ledger.
  Future<int> _supplierDebt() async {
    final row = await _db.customSelect(
      '''
      SELECT COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount_minor ELSE -amount_minor END), 0) AS balance
      FROM supplier_account_entries
      ''',
    ).getSingle();
    return row.read<int>('balance');
  }

  Future<List<TopProduct>> _topProducts(DateRange range, {int limit = 8}) async {
    final rows = await _db.customSelect(
      '''
      SELECT
        si.product_id            AS product_id,
        si.product_name_snapshot AS name,
        SUM(si.quantity_scaled)  AS quantity_scaled,
        SUM(si.total)            AS invoice_total,
        s.exchange_rate_numerator   AS rate_num,
        s.exchange_rate_denominator AS rate_den
      FROM sale_items si
      JOIN sales s ON s.id = si.sale_id
      WHERE s.status = 'posted'
        AND s.created_at >= ?1
        AND s.created_at < ?2
      GROUP BY si.product_id, si.product_name_snapshot,
               s.exchange_rate_numerator, s.exchange_rate_denominator
      ORDER BY SUM(si.total) DESC
      LIMIT ?3
      ''',
      variables: [
        Variable<String>(range.startStorage),
        Variable<String>(range.endStorage),
        Variable<int>(limit),
      ],
    ).get();

    return rows
        .map(
          (row) => TopProduct(
            productId: row.read<int>('product_id'),
            name: row.read<String>('name'),
            quantityScaled: row.read<int>('quantity_scaled'),
            baseRevenue: mulDivRound(
              row.read<int>('invoice_total'),
              row.read<int>('rate_num'),
              row.read<int>('rate_den'),
            ),
          ),
        )
        .toList();
  }

  /// Daily revenue trend.
  ///
  /// Rows are grouped in Dart by *local* calendar day. SQLite cannot apply the
  /// device's timezone offset inside `GROUP BY`, and grouping on the UTC date
  /// would place late-evening sales on the wrong local day. Only two columns
  /// are read so the working set stays small even for a month of trading.
  Future<List<SalesTrendPoint>> _salesTrend(DateRange range) async {
    final rows = await _db.customSelect(
      '''
      SELECT created_at, base_total
      FROM sales
      WHERE status = 'posted'
        AND created_at >= ?1
        AND created_at < ?2
      ORDER BY created_at ASC
      ''',
      variables: [
        Variable<String>(range.startStorage),
        Variable<String>(range.endStorage),
      ],
    ).get();

    final totals = <String, int>{};
    for (final row in rows) {
      final local = fromStorageTimestamp(row.read<String>('created_at')).toLocal();
      final key = '${local.year.toString().padLeft(4, '0')}-'
          '${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
      totals[key] = (totals[key] ?? 0) + row.read<int>('base_total');
    }

    // Emit one point per local day in the range, including days with no sales,
    // so the chart shows genuine gaps instead of compressing them.
    final points = <SalesTrendPoint>[];
    var cursor = range.start.toLocal();
    final endLocal = range.endExclusive.toLocal();
    while (cursor.isBefore(endLocal)) {
      final key = '${cursor.year.toString().padLeft(4, '0')}-'
          '${cursor.month.toString().padLeft(2, '0')}-'
          '${cursor.day.toString().padLeft(2, '0')}';
      points.add(SalesTrendPoint(day: cursor, baseTotal: totals[key] ?? 0));
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }
    return points;
  }

  Future<List<RecentTransaction>> _recentTransactions({int limit = 10}) async {
    final rows = await _db.customSelect(
      '''
      SELECT 'sale' AS kind, invoice_no AS reference, base_total AS amount, created_at
      FROM sales
      WHERE status = 'posted'
      UNION ALL
      SELECT 'purchase' AS kind, invoice_no AS reference, base_total AS amount, created_at
      FROM purchases
      WHERE status = 'posted'
      ORDER BY created_at DESC
      LIMIT ?1
      ''',
      variables: [Variable<int>(limit)],
    ).get();

    return rows
        .map(
          (row) => RecentTransaction(
            label: row.read<String>('kind'),
            reference: row.read<String>('reference'),
            baseAmount: row.read<int>('amount'),
            createdAtStorage: row.read<String>('created_at'),
            isSale: row.read<String>('kind') == 'sale',
          ),
        )
        .toList();
  }
}
