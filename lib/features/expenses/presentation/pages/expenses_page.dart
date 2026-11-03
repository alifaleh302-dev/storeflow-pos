import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Expenses feature page.
///
/// Scheduled for Phase 5. Until then this page reports its status honestly
/// rather than showing placeholder data.
class ExpensesPage extends StatelessWidget {
  const ExpensesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Expenses',
      plannedPhase: 'Phase 5',
      summary: 'Expense categories and records included in net profit.',
    );
  }
}
