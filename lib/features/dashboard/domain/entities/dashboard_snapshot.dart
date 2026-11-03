import '../../../../core/money/money.dart';
import 'dashboard_period.dart';

/// One point on the sales trend chart.
class SalesTrendPoint {
  const SalesTrendPoint({required this.day, required this.baseTotal});

  /// Local calendar day this point represents.
  final DateTime day;

  /// Posted revenue in base-currency minor units for that day.
  final int baseTotal;
}

/// A product ranked by revenue within the selected period.
class TopProduct {
  const TopProduct({
    required this.productId,
    required this.name,
    required this.quantityScaled,
    required this.baseRevenue,
  });

  final int productId;
  final String name;
  final int quantityScaled;
  final int baseRevenue;
}

/// A recently posted document shown in the activity list.
class RecentTransaction {
  const RecentTransaction({
    required this.label,
    required this.reference,
    required this.baseAmount,
    required this.createdAtStorage,
    required this.isSale,
  });

  final String label;
  final String reference;
  final int baseAmount;
  final String createdAtStorage;
  final bool isSale;
}

/// Every figure shown on the dashboard, computed from database rows.
///
/// All monetary values are base-currency minor units, except the per-invoice
/// figures which are already converted by the query that reads them. Nothing
/// here is hardcoded or estimated: each field is produced by an aggregate over
/// posted records.
class DashboardSnapshot {
  const DashboardSnapshot({
    required this.period,
    required this.baseCurrencyId,
    required this.baseCurrencyDecimalDigits,
    required this.salesTotal,
    required this.invoiceCount,
    required this.purchasesTotal,
    required this.expensesTotal,
    required this.costOfGoodsSold,
    required this.inventoryValue,
    required this.lowStockCount,
    required this.customerDebt,
    required this.supplierDebt,
    required this.topProducts,
    required this.salesTrend,
    required this.recentTransactions,
  });

  /// The window these figures cover.
  final DateRange period;

  /// Currency all figures are expressed in.
  final int baseCurrencyId;

  /// Precision of the base currency, needed to render [Money] values.
  final int baseCurrencyDecimalDigits;

  /// Posted sales revenue (after discounts) in the period.
  final int salesTotal;

  /// Number of posted invoices in the period.
  final int invoiceCount;

  /// Posted purchase totals in the period.
  final int purchasesTotal;

  /// Expenses recorded in the period.
  final int expensesTotal;

  /// Weighted-average cost of the goods sold in the period.
  final int costOfGoodsSold;

  /// Current inventory value at weighted-average cost (period-independent).
  final int inventoryValue;

  /// Products at or below their minimum stock level (period-independent).
  final int lowStockCount;

  /// Outstanding customer receivables (period-independent).
  final int customerDebt;

  /// Outstanding supplier payables (period-independent).
  final int supplierDebt;

  /// Best-selling products in the period.
  final List<TopProduct> topProducts;

  /// Daily revenue trend across the period.
  final List<SalesTrendPoint> salesTrend;

  /// Most recent posted documents.
  final List<RecentTransaction> recentTransactions;

  /// Gross profit = revenue after discounts minus cost of goods sold.
  int get grossProfit => salesTotal - costOfGoodsSold;

  /// Net operating profit = gross profit minus operating expenses.
  int get netOperatingProfit => grossProfit - expensesTotal;

  /// Convenience wrapper so widgets can format without repeating precision.
  Money money(int minorUnits) =>
      Money(minorUnits, decimalDigits: baseCurrencyDecimalDigits);
}
