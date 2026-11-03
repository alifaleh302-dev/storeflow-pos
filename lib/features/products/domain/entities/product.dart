import '../../../../core/money/money.dart';
import '../../../../core/money/quantity.dart';
import '../../../../core/money/rounding.dart';
import '../../../../core/money/weighted_average.dart';

/// A product as the application reasons about it.
///
/// Prices are [Money] in the base currency, so a caller cannot accidentally
/// combine a product's price with an amount in another currency without going
/// through an explicit conversion. The average cost is a plain integer because
/// it is always base-currency minor units and is compared, not formatted, in the
/// hot paths.
class Product {
  const Product({
    required this.id,
    required this.name,
    required this.isActive,
    required this.createdAtStorage,
    required this.updatedAtStorage,
    this.sku,
    this.categoryId,
    this.categoryName,
    this.unitId,
    this.unitName,
    this.unitSymbol,
    this.purchaseCostMinor,
    this.sellingPriceMinor,
    this.minimumStockScaled = 0,
    this.description,
    this.imagePath,
    this.barcodes = const <String>[],
    this.stockQuantityScaled = 0,
    this.averageCostMinor = 0,
    this.hasStockRow = false,
  });

  final int id;
  final String name;
  final String? sku;
  final int? categoryId;

  /// Resolved for display so a list does not have to join on every row.
  final String? categoryName;

  final int? unitId;
  final String? unitName;
  final String? unitSymbol;

  /// Purchase cost in base-currency minor units, as entered on the product.
  final int? purchaseCostMinor;

  /// Default selling price in base-currency minor units.
  final int? sellingPriceMinor;

  /// Reorder threshold, scaled by [Quantity.scale].
  final int minimumStockScaled;

  final String? description;
  final String? imagePath;
  final bool isActive;
  final String createdAtStorage;
  final String updatedAtStorage;

  /// Every barcode assigned to this product, in assignment order.
  final List<String> barcodes;

  /// Current stock, scaled. Meaningful only when [hasStockRow] is true.
  final int stockQuantityScaled;

  /// Current weighted-average cost in base-currency minor units.
  final int averageCostMinor;

  /// Whether a `product_stock` row exists. A product that has never moved stock
  /// has no row, which is different from having a row with a zero quantity.
  final bool hasStockRow;

  /// The selling price, with the caller's currency precision applied.
  Money sellingPriceIn(int decimalDigits) =>
      Money(sellingPriceMinor ?? 0, decimalDigits: decimalDigits);

  Money purchaseCostIn(int decimalDigits) =>
      Money(purchaseCostMinor ?? 0, decimalDigits: decimalDigits);

  Quantity get stockQuantity => Quantity(stockQuantityScaled);

  Quantity get minimumStock => Quantity(minimumStockScaled);

  /// Whether stock is at or below the reorder threshold.
  ///
  /// A product with no stock row counts as low stock when a threshold is set,
  /// because it has never been received and therefore cannot be sold.
  bool get isLowStock =>
      isActive && stockQuantityScaled <= minimumStockScaled && minimumStockScaled > 0;

  bool get isOutOfStock => stockQuantityScaled <= 0;

  /// Value of the stock on hand in base-currency minor units.
  ///
  /// Delegates to [WeightedAverage.stockValue] so the rounding rule lives in one
  /// place and cannot diverge between this getter and the reports.
  int stockValueMinor() => WeightedAverage.stockValue(
        quantityScaled: stockQuantityScaled,
        averageCost: averageCostMinor,
      );

  @override
  String toString() => 'Product($id, $name)';
}

/// A filter applied to a product listing.
///
/// Modelled as a value object so the query builder receives one description of
/// what to fetch rather than a growing list of nullable parameters.
class ProductFilter {
  const ProductFilter({
    this.searchTerm,
    this.categoryId,
    this.unitId,
    this.includeArchived = false,
    this.lowStockOnly = false,
    this.onlyOutOfStock = false,
  });

  /// Matched against name, SKU and barcode.
  final String? searchTerm;

  final int? categoryId;
  final int? unitId;

  /// When false (the default) archived products are hidden.
  final bool includeArchived;

  /// Restrict to products at or below their reorder threshold.
  final bool lowStockOnly;

  /// Restrict to products with no stock on hand.
  final bool onlyOutOfStock;

  ProductFilter copyWith({
    String? searchTerm,
    int? categoryId,
    int? unitId,
    bool? includeArchived,
    bool? lowStockOnly,
    bool? onlyOutOfStock,
    bool clearSearch = false,
    bool clearCategory = false,
    bool clearUnit = false,
  }) {
    return ProductFilter(
      searchTerm: clearSearch ? null : (searchTerm ?? this.searchTerm),
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      unitId: clearUnit ? null : (unitId ?? this.unitId),
      includeArchived: includeArchived ?? this.includeArchived,
      lowStockOnly: lowStockOnly ?? this.lowStockOnly,
      onlyOutOfStock: onlyOutOfStock ?? this.onlyOutOfStock,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProductFilter &&
      other.searchTerm == searchTerm &&
      other.categoryId == categoryId &&
      other.unitId == unitId &&
      other.includeArchived == includeArchived &&
      other.lowStockOnly == lowStockOnly &&
      other.onlyOutOfStock == onlyOutOfStock;

  @override
  int get hashCode => Object.hash(
        searchTerm,
        categoryId,
        unitId,
        includeArchived,
        lowStockOnly,
        onlyOutOfStock,
      );
}

/// A category, optionally nested under a parent.
class Category {
  const Category({
    required this.id,
    required this.name,
    required this.isActive,
    this.parentId,
    this.parentName,
  });

  final int id;
  final String name;
  final int? parentId;
  final String? parentName;
  final bool isActive;

  bool get isRoot => parentId == null;
}

/// A unit of measure with its display precision.
class UnitOfMeasure {
  const UnitOfMeasure({
    required this.id,
    required this.code,
    required this.name,
    required this.symbol,
    required this.quantityPrecision,
    required this.isActive,
  });

  final int id;
  final String code;
  final String name;
  final String symbol;

  /// How many decimal places are meaningful for this unit. Display only:
  /// storage is always at [Quantity.scale].
  final int quantityPrecision;

  final bool isActive;

  /// Formats a scaled quantity at this unit's precision.
  ///
  /// The value is rounded to the unit's precision for display only; the stored
  /// quantity keeps the full three-decimal scale, so nothing is lost by showing
  /// a piece count as a whole number.
  String formatQuantity(int scaledValue) {
    if (quantityPrecision >= Quantity.decimalDigits) {
      return Quantity(scaledValue).toDisplayString();
    }
    final divisor = _pow10(Quantity.decimalDigits - quantityPrecision);
    return Quantity(mulDivRound(scaledValue, 1, divisor, mode: RoundingMode.halfUp)
            * divisor)
        .toDisplayString();
  }

  static int _pow10(int exponent) {
    var result = 1;
    for (var i = 0; i < exponent; i++) {
      result *= 10;
    }
    return result;
  }
}
