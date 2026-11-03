import 'package:flutter/material.dart';

/// Brand palette for StoreFlow POS.
///
/// A single seed colour drives the Material 3 colour scheme in both light and
/// dark themes, so every derived role (primary, surface, outline) stays
/// internally consistent.
abstract final class AppColors {
  /// Deep teal: readable on retail screens, distinct from the default blue.
  static const Color seed = Color(0xFF00695C);

  /// Accent used for positive financial figures.
  static const Color positive = Color(0xFF2E7D32);

  /// Accent used for negative figures and destructive confirmations.
  static const Color negative = Color(0xFFC62828);

  /// Accent used for low-stock and near-limit warnings.
  static const Color warning = Color(0xFFEF6C00);

  /// Neutral surface for data tables on desktop.
  static const Color tableStripe = Color(0x0D000000);
}
