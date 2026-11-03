import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Inventory feature page.
///
/// Scheduled for Phase 2. Until then this page reports its status honestly
/// rather than showing placeholder data.
class InventoryPage extends StatelessWidget {
  const InventoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Inventory',
      plannedPhase: 'Phase 2',
      summary: 'Stock balances, the movement ledger, adjustments and reconciliation.',
    );
  }
}
