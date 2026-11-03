import 'package:flutter/material.dart';

import '../../../../shared/widgets/pending_module_view.dart';

/// Create/edit form for a product. Scheduled for Phase 2.
class ProductFormPage extends StatelessWidget {
  const ProductFormPage({this.productId, super.key});

  /// When null the form creates a new product; otherwise it edits this product.
  final int? productId;

  @override
  Widget build(BuildContext context) {
    return const PendingModulePage(
      title: 'Product form',
      plannedPhase: 'Phase 2',
      summary: 'Validation, barcode management and price/cost entry.',
    );
  }
}
