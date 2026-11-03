import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Product detail view with stock and movement history. Scheduled for Phase 2.
class ProductDetailPage extends StatelessWidget {
  const ProductDetailPage({required this.productId, super.key});

  final int productId;

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Product details',
      plannedPhase: 'Phase 2',
      summary: 'Stock level, valuation, barcodes and movement history.',
    );
  }
}
