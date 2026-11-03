import 'quantity.dart';
import 'rounding.dart';

/// Weighted-average inventory costing.
///
/// The default valuation method for the whole application. Every figure here is
/// an integer: quantities are scaled by [Quantity.scale] and costs are integer
/// minor units, so nothing passes through a `double`.
///
/// ## Why the average is recomputed rather than accumulated
///
/// The obvious implementation keeps a running total value and divides on read.
/// That drifts: each division rounds, and the rounded value is then reused. This
/// implementation recomputes the average from the two quantities that matter
/// (what was already on hand and what just arrived) and rounds exactly once, so
/// the result does not depend on how many movements preceded it.
abstract final class WeightedAverage {
  /// Returns the new average unit cost after receiving [inboundScaled] units at
  /// [unitCost] minor units each.
  ///
  /// `oldQuantityScaled` is the quantity on hand *before* this receipt and
  /// `oldAverageCost` is the average cost before it.
  ///
  /// When there was no positive stock on hand the incoming cost simply becomes
  /// the new average. That is the correct treatment for two reasons: there is
  /// nothing to weight against, and it is the only way to recover cleanly from a
  /// state where stock was zero or negative (for example a shop that enabled
  /// negative stock and has since restocked).
  static int applyInbound({
    required int oldQuantityScaled,
    required int oldAverageCost,
    required int inboundScaled,
    required int unitCost,
    RoundingMode mode = RoundingMode.halfUp,
  }) {
    if (inboundScaled <= 0) {
      throw ArgumentError.value(
        inboundScaled,
        'inboundScaled',
        'Inbound quantity must be greater than zero',
      );
    }
    if (unitCost < 0) {
      throw ArgumentError.value(unitCost, 'unitCost', 'Cost cannot be negative');
    }
    if (oldQuantityScaled <= 0) {
      return unitCost;
    }
    // new = (oldQty * oldAvg + inQty * cost) / (oldQty + inQty)
    final oldValue = oldQuantityScaled * oldAverageCost;
    final inboundValue = inboundScaled * unitCost;
    final newQuantity = oldQuantityScaled + inboundScaled;
    return divRound(oldValue + inboundValue, newQuantity, mode: mode);
  }

  /// Total value of the stock on hand, in minor units.
  static int stockValue({
    required int quantityScaled,
    required int averageCost,
    RoundingMode mode = RoundingMode.halfUp,
  }) {
    if (quantityScaled <= 0) return 0;
    return mulDivRound(quantityScaled, averageCost, Quantity.scale, mode: mode);
  }

  /// Cost of goods for [quantityScaled] units at [averageCost].
  ///
  /// Used for a sale line's cost snapshot and for cost of goods sold. The result
  /// is rounded once, here, and then stored, so a report never re-derives it.
  static int costOfGoods({
    required int quantityScaled,
    required int averageCost,
    RoundingMode mode = RoundingMode.halfUp,
  }) {
    return mulDivRound(quantityScaled, averageCost, Quantity.scale, mode: mode);
  }

  /// The average cost to carry after removing [outboundScaled] units.
  ///
  /// An outflow does not change the average cost of what remains — that is the
  /// defining property of weighted-average costing, as opposed to FIFO. This
  /// method exists so callers do not have to know that, and so the invariant is
  /// stated in one place.
  static int applyOutbound({
    required int oldQuantityScaled,
    required int oldAverageCost,
    required int outboundScaled,
  }) {
    if (outboundScaled <= 0) {
      throw ArgumentError.value(
        outboundScaled,
        'outboundScaled',
        'Outbound quantity must be greater than zero',
      );
    }
    return oldAverageCost;
  }

  /// Reverses a receipt of [inboundScaled] units that were averaged into a
  /// balance of [quantityScaled] at [averageCost].
  ///
  /// Used when a posted purchase is returned or voided. The value that the
  /// receipt contributed is `inboundScaled * unitCost`; subtracting it and
  /// dividing by the remaining quantity restores the pre-receipt average, which
  /// is what keeps a voided purchase from leaving a permanent trace in the cost.
  ///
  /// Returns the incoming [unitCost] unchanged when nothing would remain, which
  /// is the same convention [applyInbound] uses for an empty stock position.
  static int reverseInbound({
    required int quantityScaled,
    required int averageCost,
    required int inboundScaled,
    required int unitCost,
    RoundingMode mode = RoundingMode.halfUp,
  }) {
    final remaining = quantityScaled - inboundScaled;
    if (remaining <= 0) {
      return unitCost;
    }
    final currentValue = quantityScaled * averageCost;
    final removedValue = inboundScaled * unitCost;
    final remainingValue = currentValue - removedValue;
    if (remainingValue < 0) {
      // The receipt's contribution exceeds the whole current value, which can
      // only happen if the average has since been dragged down by cheaper
      // receipts. Clamping to zero is the honest floor: the store cannot have a
      // negative inventory value, and the discrepancy is visible in the ledger.
      return 0;
    }
    return divRound(remainingValue, remaining, mode: mode);
  }
}
