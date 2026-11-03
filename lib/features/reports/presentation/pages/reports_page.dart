import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Reports feature page.
///
/// Scheduled for Phase 8. Until then this page reports its status honestly
/// rather than showing placeholder data.
class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Reports',
      plannedPhase: 'Phase 8',
      summary: 'Sales, profit, inventory, debt and cash reports with CSV export.',
    );
  }
}
