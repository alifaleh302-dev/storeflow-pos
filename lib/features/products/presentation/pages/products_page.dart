import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Products feature page.
///
/// Scheduled for Phase 2. Until then this page reports its status honestly
/// rather than showing placeholder data.
class ProductsPage extends StatelessWidget {
  const ProductsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Products',
      plannedPhase: 'Phase 2',
      summary: 'Product CRUD, barcodes, categories, units, CSV import and export.',
    );
  }
}
