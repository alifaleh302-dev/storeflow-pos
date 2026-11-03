import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Sales history feature page.
///
/// Scheduled for Phase 3. Until then this page reports its status honestly
/// rather than showing placeholder data.
class SalesHistoryPage extends StatelessWidget {
  const SalesHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Sales history',
      plannedPhase: 'Phase 3',
      summary: 'Posted invoices, void workflow and receipt reprint.',
    );
  }
}
