import '../../../../core/constants/enums.dart';
import '../../../../core/money/money.dart';
import '../../../../core/money/quantity.dart';
import '../../../../core/money/rounding.dart';

/// One line of a purchase as it will be received.
class PurchaseLine {
  const PurchaseLine({
    this.id,
    required this.productId,
    required this.productName,
    required this.quantityScaled,
    required this.unitCostMinor,
    this.lineDiscountMinor = 0,
  });

  final int? id;
  final int productId;
  final String productName;

  /// Quantity, scaled by [Quantity.scale].
  final int quantityScaled;

  /// Cost per unit in the purchase's currency, in minor units.
  final int unitCostMinor;

  /// Discount on this line, in the purchase's currency.
  final int lineDiscountMinor;

  Quantity get quantity => Quantity(quantityScaled);

  /// Value before the line discount.
  int get grossMinor =>
      mulDivRound(quantityScaled, unitCostMinor, Quantity.scale);

  /// Value after the line discount, never negative.
  int get netMinor {
    final value = grossMinor - lineDiscountMinor;
    return value < 0 ? 0 : value;
  }

  PurchaseLine copyWith({int? quantityScaled, int? unitCostMinor}) {
    return PurchaseLine(
      id: id,
      productId: productId,
      productName: productName,
      quantityScaled: quantityScaled ?? this.quantityScaled,
      unitCostMinor: unitCostMinor ?? this.unitCostMinor,
      lineDiscountMinor: lineDiscountMinor,
    );
  }
}

/// A payment made against a purchase.
class PurchasePayment {
  const PurchasePayment({
    required this.paymentMethod,
    required this.currencyId,
    required this.amountMinor,
    required this.exchangeRateNumerator,
    required this.exchangeRateDenominator,
    required this.baseAmountMinor,
    this.id,
    this.cashSessionId,
    this.notes,
  });

  final int? id;
  final PaymentMethod paymentMethod;
  final int currencyId;
  final int amountMinor;
  final int exchangeRateNumerator;
  final int exchangeRateDenominator;
  final int baseAmountMinor;
  final int? cashSessionId;
  final String? notes;

  bool get isCredit => paymentMethod.isCredit;
}

/// A posted purchase invoice.
class Purchase {
  const Purchase({
    required this.id,
    required this.invoiceNo,
    required this.currencyId,
    required this.exchangeRateNumerator,
    required this.exchangeRateDenominator,
    required this.subtotalMinor,
    required this.discountMinor,
    required this.additionalCostMinor,
    required this.totalMinor,
    required this.paidAmountMinor,
    required this.baseTotalMinor,
    required this.basePaidAmountMinor,
    required this.status,
    required this.createdAtStorage,
    required this.updatedAtStorage,
    this.supplierId,
    this.supplierName,
    this.supplierReference,
    this.cashSessionId,
    this.userId,
    this.notes,
    this.lines = const <PurchaseLine>[],
    this.payments = const <PurchasePayment>[],
    this.currencyCode,
    this.currencyDecimalDigits = 2,
  });

  final int id;
  final String invoiceNo;
  final int? supplierId;
  final String? supplierName;
  final int currencyId;
  final String? currencyCode;
  final int currencyDecimalDigits;

  /// Rate from the purchase currency to the base currency, as stored.
  final int exchangeRateNumerator;
  final int exchangeRateDenominator;

  final int subtotalMinor;
  final int discountMinor;
  final int additionalCostMinor;
  final int totalMinor;
  final int paidAmountMinor;
  final int baseTotalMinor;
  final int basePaidAmountMinor;

  final DocumentStatus status;
  final int? cashSessionId;
  final int? userId;

  /// The supplier's own invoice number, kept for reconciliation.
  final String? supplierReference;

  final String? notes;
  final String createdAtStorage;
  final String updatedAtStorage;
  final List<PurchaseLine> lines;
  final List<PurchasePayment> payments;

  Money get total => Money(totalMinor, decimalDigits: currencyDecimalDigits);

  /// Outstanding amount in base-currency minor units.
  int get baseOutstandingMinor {
    final due = baseTotalMinor - basePaidAmountMinor;
    return due < 0 ? 0 : due;
  }

  bool get isFullyPaid => baseOutstandingMinor == 0;
  bool get isCredit => baseOutstandingMinor > 0;
  bool get isVoided => status == DocumentStatus.voided;
}

/// A purchase being assembled before it is posted.
///
/// Like the sale draft, this holds the arithmetic, so the figure the user sees
/// while entering the invoice is the figure the repository persists.
class PurchaseDraft {
  const PurchaseDraft({
    required this.currencyId,
    required this.currencyDecimalDigits,
    this.supplierId,
    this.lines = const <PurchaseLine>[],
    this.discountMinor = 0,
    this.additionalCostMinor = 0,
    this.exchangeRateNumerator = 1,
    this.exchangeRateDenominator = 1,
    this.supplierReference,
    this.notes,
  });

  final int currencyId;
  final int currencyDecimalDigits;
  final int? supplierId;
  final List<PurchaseLine> lines;

  /// Discount on the whole invoice, in the purchase's currency.
  final int discountMinor;

  /// Freight, customs or handling added to the invoice, in the purchase's
  /// currency. It raises the invoice total and is therefore part of the cost of
  /// the goods received.
  final int additionalCostMinor;

  final int exchangeRateNumerator;
  final int exchangeRateDenominator;
  final String? supplierReference;
  final String? notes;

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  /// Sum of the lines after their own discounts.
  int get subtotalMinor =>
      lines.fold<int>(0, (sum, line) => sum + line.netMinor);

  /// The invoice total: lines, less the invoice discount, plus additional costs.
  int get totalMinor {
    final value = subtotalMinor - discountMinor + additionalCostMinor;
    return value < 0 ? 0 : value;
  }

  /// The total in base-currency minor units at this draft's rate.
  int get baseTotalMinor =>
      mulDivRound(totalMinor, exchangeRateNumerator, exchangeRateDenominator);

  Money get total => Money(totalMinor, decimalDigits: currencyDecimalDigits);

  /// Adds a line, merging into an existing line for the same product.
  ///
  /// Merging keeps one receipt line per product. When the two lines carry
  /// different costs the quantities are combined and the cost is re-weighted, so
  /// the resulting line total still matches what was actually paid.
  PurchaseDraft addLine(PurchaseLine line) {
    final index = lines.indexWhere((l) => l.productId == line.productId);
    if (index < 0) {
      return copyWith(lines: <PurchaseLine>[...lines, line]);
    }
    final existing = lines[index];
    final combinedQuantity = existing.quantityScaled + line.quantityScaled;
    final combinedValue = existing.netMinor + line.netMinor;
    final blendedCost = combinedQuantity == 0
        ? line.unitCostMinor
        : mulDivRound(combinedValue, Quantity.scale, combinedQuantity);
    final merged = existing.copyWith(
      quantityScaled: combinedQuantity,
      unitCostMinor: blendedCost,
    );
    return copyWith(
      lines: <PurchaseLine>[
        for (var i = 0; i < lines.length; i++)
          if (i == index) merged else lines[i],
      ],
    );
  }

  /// Sets a line's quantity, removing the line when it reaches zero.
  PurchaseDraft setQuantity(int productId, int quantityScaled) {
    if (quantityScaled <= 0) return removeLine(productId);
    return copyWith(
      lines: <PurchaseLine>[
        for (final line in lines)
          if (line.productId == productId)
            line.copyWith(quantityScaled: quantityScaled)
          else
            line,
      ],
    );
  }

  PurchaseDraft removeLine(int productId) => copyWith(
        lines: <PurchaseLine>[
          for (final line in lines)
            if (line.productId != productId) line,
        ],
      );

  PurchaseDraft copyWith({
    int? currencyId,
    int? currencyDecimalDigits,
    int? supplierId,
    List<PurchaseLine>? lines,
    int? discountMinor,
    int? additionalCostMinor,
    int? exchangeRateNumerator,
    int? exchangeRateDenominator,
    String? supplierReference,
    String? notes,
    bool clearSupplier = false,
  }) {
    return PurchaseDraft(
      currencyId: currencyId ?? this.currencyId,
      currencyDecimalDigits:
          currencyDecimalDigits ?? this.currencyDecimalDigits,
      supplierId: clearSupplier ? null : (supplierId ?? this.supplierId),
      lines: lines ?? this.lines,
      discountMinor: discountMinor ?? this.discountMinor,
      additionalCostMinor: additionalCostMinor ?? this.additionalCostMinor,
      exchangeRateNumerator: exchangeRateNumerator ?? this.exchangeRateNumerator,
      exchangeRateDenominator:
          exchangeRateDenominator ?? this.exchangeRateDenominator,
      supplierReference: supplierReference ?? this.supplierReference,
      notes: notes ?? this.notes,
    );
  }
}
