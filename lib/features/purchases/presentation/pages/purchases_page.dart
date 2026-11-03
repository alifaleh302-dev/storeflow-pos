import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Purchases feature page.
///
/// Scheduled for Phase 4. Until then this page reports its status honestly
/// rather than showing placeholder data.
class PurchasesPage extends StatelessWidget {
  const PurchasesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Purchases',
      plannedPhase: 'Phase 4',
      summary: 'Supplier invoices, weighted-average cost and supplier balances.',
    );
  }
}
