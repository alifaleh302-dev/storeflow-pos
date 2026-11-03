import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Currencies feature page.
///
/// Scheduled for Phase 6. Until then this page reports its status honestly
/// rather than showing placeholder data.
class CurrenciesPage extends StatelessWidget {
  const CurrenciesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Currencies',
      plannedPhase: 'Phase 6',
      summary: 'Base currency, additional currencies and historical exchange rates.',
    );
  }
}
