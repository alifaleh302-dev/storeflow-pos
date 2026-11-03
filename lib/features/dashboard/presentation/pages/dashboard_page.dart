import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/money/quantity.dart';
import '../../../../core/utils/timestamps.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/section_card.dart';
import '../../../../shared/widgets/state_views.dart';
import '../../domain/entities/dashboard_period.dart';
import '../../domain/entities/dashboard_snapshot.dart';
import '../providers/dashboard_providers.dart';
import '../widgets/metric_card.dart';

/// Business dashboard.
///
/// Every figure comes from [DashboardSnapshot], which is built from posted
/// database rows. When the database is empty the page shows zeros and an empty
/// activity list, never sample data.
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final snapshot = ref.watch(dashboardSnapshotProvider);
    final period = ref.watch(dashboardPeriodProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navDashboard),
        actions: <Widget>[
          IconButton(
            tooltip: l10n.actionRefresh,
            onPressed: () => ref.invalidate(dashboardSnapshotProvider),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: <Widget>[
          _PeriodSelector(selected: period),
          const Divider(height: 1),
          Expanded(
            child: snapshot.when(
              loading: () => const LoadingView(),
              error: (error, _) => ErrorView(
                message: l10n.stateError,
                details: error.toString(),
                onRetry: () => ref.invalidate(dashboardSnapshotProvider),
              ),
              data: (data) => _DashboardBody(snapshot: data),
            ),
          ),
        ],
      ),
    );
  }
}

class _PeriodSelector extends ConsumerWidget {
  const _PeriodSelector({required this.selected});

  final PeriodPreset selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final labels = <PeriodPreset, String>{
      PeriodPreset.today: l10n.periodToday,
      PeriodPreset.yesterday: l10n.periodYesterday,
      PeriodPreset.thisWeek: l10n.periodThisWeek,
      PeriodPreset.thisMonth: l10n.periodThisMonth,
      PeriodPreset.custom: l10n.periodCustom,
    };

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: <Widget>[
          for (final entry in labels.entries) ...<Widget>[
            ChoiceChip(
              label: Text(entry.value),
              selected: selected == entry.key,
              onSelected: (_) async {
                if (entry.key == PeriodPreset.custom) {
                  final now = DateTime.now();
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(now.year - 5),
                    lastDate: DateTime(now.year + 1),
                  );
                  if (picked == null) return;
                  ref
                      .read(customRangeProvider.notifier)
                      .set(DateRange.custom(picked.start, picked.end));
                }
                ref.read(dashboardPeriodProvider.notifier).select(entry.key);
              },
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _DashboardBody extends ConsumerWidget {
  const _DashboardBody({required this.snapshot});

  final DashboardSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1400
        ? 4
        : width >= 1000
            ? 3
            : width >= 640
                ? 2
                : 1;

    String amount(int minorUnits) =>
        snapshot.money(minorUnits).toDecimalString();

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(dashboardSnapshotProvider),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _MetricGrid(
            columns: columns,
            children: <Widget>[
              MetricCard(
                label: l10n.dashboardTodaySales,
                value: amount(snapshot.salesTotal),
                icon: Icons.payments_outlined,
                caption: snapshot.money(snapshot.salesTotal).toDecimalString(),
              ),
              MetricCard(
                label: l10n.dashboardInvoiceCount,
                value: snapshot.invoiceCount.toString(),
                icon: Icons.receipt_outlined,
              ),
              MetricCard(
                label: l10n.dashboardGrossProfit,
                value: amount(snapshot.grossProfit),
                icon: Icons.trending_up,
                color: snapshot.grossProfit >= 0
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
              MetricCard(
                label: l10n.dashboardNetProfit,
                value: amount(snapshot.netOperatingProfit),
                icon: Icons.account_balance,
                color: snapshot.netOperatingProfit >= 0
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
              MetricCard(
                label: l10n.dashboardTotalPurchases,
                value: amount(snapshot.purchasesTotal),
                icon: Icons.local_shipping_outlined,
              ),
              MetricCard(
                label: l10n.dashboardTotalExpenses,
                value: amount(snapshot.expensesTotal),
                icon: Icons.receipt_long_outlined,
              ),
              MetricCard(
                label: l10n.dashboardInventoryValue,
                value: amount(snapshot.inventoryValue),
                icon: Icons.warehouse_outlined,
              ),
              MetricCard(
                label: l10n.dashboardLowStock,
                value: snapshot.lowStockCount.toString(),
                icon: Icons.warning_amber_outlined,
                color: snapshot.lowStockCount > 0
                    ? Theme.of(context).colorScheme.tertiary
                    : null,
              ),
              MetricCard(
                label: l10n.dashboardCustomerDebt,
                value: amount(snapshot.customerDebt),
                icon: Icons.people_outline,
              ),
              MetricCard(
                label: l10n.dashboardSupplierDebt,
                value: amount(snapshot.supplierDebt),
                icon: Icons.storefront_outlined,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _ResponsivePair(
            wide: width >= 1000,
            first: SectionCard(
              title: l10n.dashboardSalesChart,
              child: SizedBox(
                height: 220,
                child: _SalesChart(points: snapshot.salesTrend),
              ),
            ),
            second: SectionCard(
              title: l10n.dashboardTopProducts,
              child: _TopProductsList(
                products: snapshot.topProducts,
                formatAmount: amount,
              ),
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: l10n.dashboardRecentTransactions,
            child: _RecentList(
              transactions: snapshot.recentTransactions,
              formatAmount: amount,
            ),
          ),
        ],
      ),
    );
  }
}

/// Lays metric cards out in a responsive grid without a fixed child count.
class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }
}

/// Two panels side by side on wide screens, stacked on narrow ones.
class _ResponsivePair extends StatelessWidget {
  const _ResponsivePair({
    required this.wide,
    required this.first,
    required this.second,
  });

  final bool wide;
  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    if (!wide) {
      return Column(
        children: <Widget>[
          first,
          const SizedBox(height: 16),
          second,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(flex: 3, child: first),
        const SizedBox(width: 16),
        Expanded(flex: 2, child: second),
      ],
    );
  }
}

class _SalesChart extends StatelessWidget {
  const _SalesChart({required this.points});

  final List<SalesTrendPoint> points;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (points.isEmpty) {
      return EmptyView(title: l10n.stateEmpty, icon: Icons.show_chart);
    }
    final scheme = Theme.of(context).colorScheme;
    final maxValue = points
        .map((point) => point.baseTotal)
        .fold<int>(0, (a, b) => a > b ? a : b);

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxValue == 0 ? 1 : maxValue * 1.15,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) => FlLine(
            color: scheme.outlineVariant,
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 56,
              getTitlesWidget: (value, meta) => Text(
                value.toInt().toString(),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: (points.length / 6).clamp(1, 366).toDouble(),
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= points.length) {
                  return const SizedBox.shrink();
                }
                final day = points[index].day;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${day.day}/${day.month}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                );
              },
            ),
          ),
        ),
        lineBarsData: <LineChartBarData>[
          LineChartBarData(
            spots: <FlSpot>[
              for (var i = 0; i < points.length; i++)
                FlSpot(i.toDouble(), points[i].baseTotal.toDouble()),
            ],
            isCurved: false,
            color: scheme.primary,
            barWidth: 2,
            dotData: FlDotData(show: points.length <= 31),
            belowBarData: BarAreaData(
              show: true,
              color: scheme.primary.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopProductsList extends StatelessWidget {
  const _TopProductsList({
    required this.products,
    required this.formatAmount,
  });

  final List<TopProduct> products;
  final String Function(int) formatAmount;

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) {
      return const EmptyView(icon: Icons.inventory_2_outlined);
    }
    return Column(
      children: <Widget>[
        for (final product in products)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    product.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  Quantity(product.quantityScaled).toDisplayString(),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 12),
                Text(
                  formatAmount(product.baseRevenue),
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _RecentList extends StatelessWidget {
  const _RecentList({
    required this.transactions,
    required this.formatAmount,
  });

  final List<RecentTransaction> transactions;
  final String Function(int) formatAmount;

  @override
  Widget build(BuildContext context) {
    if (transactions.isEmpty) {
      return const EmptyView(icon: Icons.history);
    }
    return Column(
      children: <Widget>[
        for (final transaction in transactions)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              transaction.isSale
                  ? Icons.point_of_sale_outlined
                  : Icons.local_shipping_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(transaction.reference),
            subtitle: Text(
              formatLocalTimestamp(transaction.createdAtStorage),
            ),
            trailing: Text(
              formatAmount(transaction.baseAmount),
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            onTap: transaction.isSale
                ? () => context.go(Routes.salesHistory)
                : () => context.go(Routes.purchases),
          ),
      ],
    );
  }
}
