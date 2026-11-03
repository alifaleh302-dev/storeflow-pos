import '../../../../core/constants/enums.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/money/quantity.dart';
import '../../../../core/money/rounding.dart';
import '../../../../core/money/weighted_average.dart';

/// Pure decisions about stock, with no database and no Flutter dependency.
///
/// Every rule that decides *whether* a stock change is allowed, and *what the
/// resulting balance and cost are*, lives here. The repository calls these
/// functions and then persists the answer, so the rules can be unit-tested on
/// the Dart VM without a database and cannot drift between call sites.
abstract final class InventoryPolicy {
  /// Decides whether [requestedScaled] units of a product may leave stock.
  ///
  /// Throws [InsufficientStockFailure] when the movement would take the balance
  /// below zero and negative stock is not permitted. When [allowNegativeStock]
  /// is true the check is skipped — a deliberate, configured relaxation, not a
  /// silent one.
  ///
  /// A non-positive request is rejected outright: a "sale" of zero or a negative
  /// quantity is always a bug upstream, and accepting it would corrupt the
  /// ledger with a meaningless row.
  static void assertCanIssue({
    required int productId,
    required String productName,
    required int availableScaled,
    required int requestedScaled,
    required bool allowNegativeStock,
  }) {
    if (requestedScaled <= 0) {
      throw ValidationFailure(
        'Quantity must be greater than zero',
        field: 'quantity',
        details: <String, Object?>{
          'productId': productId,
          'requestedScaled': requestedScaled,
        },
      );
    }
    if (allowNegativeStock) return;
    if (availableScaled - requestedScaled < 0) {
      throw InsufficientStockFailure(
        productName: productName,
        availableScaled: availableScaled,
        requestedScaled: requestedScaled,
      );
    }
  }

  /// Computes the balance after applying a signed [signedQuantityScaled].
  ///
  /// The sign must agree with the movement type's declared direction. A mismatch
  /// means the caller has confused an inbound movement with an outbound one,
  /// which would invert the ledger; it is rejected rather than corrected.
  static int balanceAfter({
    required MovementType movementType,
    required int signedQuantityScaled,
    required int currentScaled,
  }) {
    if (signedQuantityScaled == 0) {
      throw ValidationFailure(
        'A stock movement cannot have a zero quantity',
        field: 'quantity',
      );
    }
    final expectedSign = movementType.direction;
    if (expectedSign != 0 && signedQuantityScaled.sign != expectedSign) {
      throw ValidationFailure(
        'Movement type ${movementType.wireValue} expects a '
        '${expectedSign > 0 ? 'positive' : 'negative'} quantity',
        field: 'quantity',
        details: <String, Object?>{
          'movementType': movementType.wireValue,
          'quantityScaled': signedQuantityScaled,
        },
      );
    }
    return currentScaled + signedQuantityScaled;
  }

  /// The average cost after applying a signed movement.
  ///
  /// An inbound movement re-weights the average; an outbound movement leaves it
  /// untouched, which is the defining property of weighted-average costing.
  /// [unitCost] is required for inbound movements and ignored for outbound ones.
  static int averageCostAfter({
    required MovementType movementType,
    required int currentQuantityScaled,
    required int currentAverageCost,
    required int signedQuantityScaled,
    required int unitCost,
    RoundingMode mode = RoundingMode.halfUp,
  }) {
    switch (movementType) {
      case MovementType.purchase:
      case MovementType.customerReturn:
      case MovementType.adjustmentIn:
      case MovementType.openingStock:
        return WeightedAverage.applyInbound(
          oldQuantityScaled: currentQuantityScaled,
          oldAverageCost: currentAverageCost,
          inboundScaled: signedQuantityScaled.abs(),
          unitCost: unitCost,
          mode: mode,
        );
      case MovementType.sale:
      case MovementType.adjustmentOut:
      case MovementType.damage:
        return currentAverageCost;
      case MovementType.supplierReturn:
        // A return to a supplier removes units that were averaged in, so the
        // average must be unwound rather than left inflated by stock that is no
        // longer here.
        return WeightedAverage.reverseInbound(
          quantityScaled: currentQuantityScaled,
          averageCost: currentAverageCost,
          inboundScaled: signedQuantityScaled.abs(),
          unitCost: unitCost == 0 ? currentAverageCost : unitCost,
          mode: mode,
        );
    }
  }

  /// Validates that a movement's quantity is representable at the storage scale.
  ///
  /// Guards against a caller passing a raw unscaled value such as `3` when it
  /// meant three units (`3000`), which would silently record a thousandth of the
  /// intended quantity.
  static void assertScaled(int value, {required String field}) {
    if (value == 0) {
      throw ValidationFailure(
        '$field cannot be zero',
        field: field,
      );
    }
  }

  /// Whether a movement type increases stock.
  static bool isInbound(MovementType type) => type.direction > 0;

  /// The quantity precision implied by a unit, used to reject a product whose
  /// unit cannot express the quantity being moved.
  static bool quantityFitsUnit({
    required int scaledQuantity,
    required int unitPrecision,
  }) {
    if (unitPrecision >= Quantity.decimalDigits) return true;
    final divisor = _pow10(Quantity.decimalDigits - unitPrecision);
    return scaledQuantity % divisor == 0;
  }

  static int _pow10(int exponent) {
    var result = 1;
    for (var i = 0; i < exponent; i++) {
      result *= 10;
    }
    return result;
  }
}
