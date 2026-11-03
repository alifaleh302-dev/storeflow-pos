import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Customers feature page.
///
/// Scheduled for Phase 5. Until then this page reports its status honestly
/// rather than showing placeholder data.
class CustomersPage extends StatelessWidget {
  const CustomersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Customers',
      plannedPhase: 'Phase 5',
      summary: 'Customer records, balances, statements and payments.',
    );
  }
}
