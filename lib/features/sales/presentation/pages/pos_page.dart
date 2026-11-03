import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Point of Sale feature page.
///
/// Scheduled for Phase 3. Until then this page reports its status honestly
/// rather than showing placeholder data.
class PosPage extends StatelessWidget {
  const PosPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Point of Sale',
      plannedPhase: 'Phase 3',
      summary: 'Cart, barcode input, discounts, split payments and atomic checkout.',
    );
  }
}
