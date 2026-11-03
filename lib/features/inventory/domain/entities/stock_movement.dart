import '../../../../core/constants/enums.dart';
import '../../../../core/money/quantity.dart';

/// One entry in the inventory ledger.
///
/// The ledger is append-only and is the authoritative record of what happened to
/// stock. [balanceAfterScaled] is the quantity on hand immediately after this
/// movement, which makes a discrepancy localisable to the movement that caused
/// it instead of requiring a full replay to find.
class StockMovement {
  const StockMovement({
    required this.id,
    required this.productId,
    required this.movementType,
    required this.quantityScaled,
    required this.balanceAfterScaled,
    required this.referenceType,
    required this.createdAtStorage,
    this.referenceId,
    this.notes,
    this.productName,
    this.unitSymbol,
  });

  final int id;
  final int productId;

  /// Resolved for display in the movement history.
  final String? productName;
  final String? unitSymbol;

  final MovementType movementType;

  /// Signed: positive increases stock, negative decreases it. The sign always
  /// matches [MovementType.direction], which the repository validates.
  final int quantityScaled;

  final int balanceAfterScaled;
  final ReferenceType referenceType;
  final int? referenceId;
  final String? notes;
  final String createdAtStorage;

  Quantity get quantity => Quantity(quantityScaled);
  Quantity get balanceAfter => Quantity(balanceAfterScaled);

  bool get isInbound => quantityScaled > 0;

  @override
  String toString() =>
      'StockMovement($id, ${movementType.wireValue}, $quantityScaled)';
}

/// The current stock position of one product.
class StockPosition {
  const StockPosition({
    required this.productId,
    required this.quantityScaled,
    required this.averageCostMinor,
    this.hasRow = true,
  });

  /// A product that has never had a stock row, i.e. zero on hand at zero cost.
  const StockPosition.absent(this.productId)
      : quantityScaled = 0,
        averageCostMinor = 0,
        hasRow = false;

  final int productId;
  final int quantityScaled;

  /// Weighted-average cost in base-currency minor units.
  final int averageCostMinor;

  /// Whether a `product_stock` row exists. A missing row and a row holding zero
  /// are treated identically for arithmetic, but the distinction is kept so a
  /// product that has never moved stock is not mistaken for one that has been
  /// counted down to zero.
  final bool hasRow;

  Quantity get quantity => Quantity(quantityScaled);

  int get valueMinor =>
      quantityScaled <= 0 ? 0 : (quantityScaled * averageCostMinor) ~/ Quantity.scale;

  @override
  String toString() =>
      'StockPosition($productId, qty=$quantityScaled, avg=$averageCostMinor)';
}

/// The outcome of a reconciliation between the cached balance and the ledger.
class StockReconciliation {
  const StockReconciliation({
    required this.productId,
    required this.productName,
    required this.cachedScaled,
    required this.ledgerScaled,
  });

  final int productId;
  final String productName;

  /// The value in `product_stock`.
  final int cachedScaled;

  /// The signed sum of `inventory_movements` for this product.
  final int ledgerScaled;

  int get differenceScaled => cachedScaled - ledgerScaled;

  bool get isConsistent => differenceScaled == 0;

  @override
  String toString() =>
      'StockReconciliation($productName, cached=$cachedScaled, ledger=$ledgerScaled)';
}
