import '../../../../core/constants/enums.dart';
import '../../../../core/money/money.dart';
import '../../../../core/money/quantity.dart';
import '../../../../core/money/rounding.dart';

/// One line of a sale, as it was priced and costed at the moment of posting.
///
/// Every value a later report might need is snapshotted here. A change to a
/// product's price or its weighted-average cost therefore cannot alter a posted
/// invoice or its reported profit, which is what makes historical reports
/// trustworthy.
class SaleLine {
  const SaleLine({
    this.id,
    required this.productId,
    required this.productName,
    required this.quantityScaled,
    required this.unitPriceMinor,
    required this.unitCostMinor,
    this.sku,
    this.lineDiscountMinor = 0,
  });

  final int? id;
  final int productId;
  final String productName;
  final String? sku;

  /// Quantity, scaled by [Quantity.scale].
  final int quantityScaled;

  /// Selling price per unit in the sale's currency, in minor units.
  final int unitPriceMinor;

  /// Weighted-average cost per unit in base-currency minor units, snapshotted.
  final int unitCostMinor;

  /// Discount applied to this line, in the sale's currency.
  final int lineDiscountMinor;

  Quantity get quantity => Quantity(quantityScaled);

  /// Gross value of the line before its discount.
  int get grossMinor =>
      mulDivRound(quantityScaled, unitPriceMinor, Quantity.scale);

  /// Value of the line after its discount. Never negative: a discount larger
  /// than the line is a data error, and a negative line would corrupt the total.
  int get netMinor {
    final value = grossMinor - lineDiscountMinor;
    return value < 0 ? 0 : value;
  }

  /// Cost of goods for this line, in base-currency minor units.
  int get costMinor =>
      mulDivRound(quantityScaled, unitCostMinor, Quantity.scale);

  /// Profit on this line before any invoice-level discount, in base currency.
  int get grossProfitMinor => netMinor - costMinor;

  Money netIn(int decimalDigits) =>
      Money(netMinor, decimalDigits: decimalDigits);

  Money unitPriceIn(int decimalDigits) =>
      Money(unitPriceMinor, decimalDigits: decimalDigits);

  SaleLine copyWith({
    int? quantityScaled,
    int? unitPriceMinor,
    int? lineDiscountMinor,
    String? productName,
  }) {
    return SaleLine(
      id: id,
      productId: productId,
      productName: productName ?? this.productName,
      sku: sku,
      quantityScaled: quantityScaled ?? this.quantityScaled,
      unitPriceMinor: unitPriceMinor ?? this.unitPriceMinor,
      unitCostMinor: unitCostMinor,
      lineDiscountMinor: lineDiscountMinor ?? this.lineDiscountMinor,
    );
  }
}

/// A payment allocation against a sale.
///
/// A split payment is modelled as several of these rather than as one payment
/// with a special method, so each tender keeps its own currency and the rate that
/// applied to it.
class SalePayment {
  const SalePayment({
    required this.paymentMethod,
    required this.currencyId,
    required this.amountMinor,
    required this.exchangeRateNumerator,
    required this.exchangeRateDenominator,
    required this.baseAmountMinor,
    this.id,
    this.cashSessionId,
    this.notes,
    this.createdAtStorage,
  });

  final int? id;
  final PaymentMethod paymentMethod;
  final int currencyId;

  /// Amount tendered, in [currencyId] minor units.
  final int amountMinor;

  final int exchangeRateNumerator;
  final int exchangeRateDenominator;

  /// The same tender expressed in base-currency minor units, as recorded.
  final int baseAmountMinor;

  final int? cashSessionId;
  final String? notes;
  final String? createdAtStorage;

  bool get isCredit => paymentMethod.isCredit;

  /// Only cash affects the physical drawer.
  bool get affectsCashDrawer => paymentMethod.isCash;
}

/// A posted sale invoice.
class Sale {
  const Sale({
    required this.id,
    required this.invoiceNo,
    required this.currencyId,
    required this.exchangeRateNumerator,
    required this.exchangeRateDenominator,
    required this.subtotalMinor,
    required this.lineDiscountTotalMinor,
    required this.invoiceDiscountMinor,
    required this.totalMinor,
    required this.paidAmountMinor,
    required this.costTotalMinor,
    required this.baseSubtotalMinor,
    required this.baseTotalMinor,
    required this.basePaidAmountMinor,
    required this.baseCostTotalMinor,
    required this.status,
    required this.createdAtStorage,
    required this.updatedAtStorage,
    this.customerId,
    this.customerName,
    this.cashSessionId,
    this.userId,
    this.notes,
    this.lines = const <SaleLine>[],
    this.payments = const <SalePayment>[],
    this.currencyCode,
    this.currencySymbol,
    this.currencyDecimalDigits = 2,
  });

  final int id;
  final String invoiceNo;
  final int? customerId;
  final String? customerName;
  final int currencyId;
  final String? currencyCode;
  final String? currencySymbol;
  final int currencyDecimalDigits;

  /// Rate from the sale currency to the base currency, as stored.
  final int exchangeRateNumerator;
  final int exchangeRateDenominator;

  final int subtotalMinor;
  final int lineDiscountTotalMinor;
  final int invoiceDiscountMinor;
  final int totalMinor;
  final int paidAmountMinor;
  final int costTotalMinor;

  final int baseSubtotalMinor;
  final int baseTotalMinor;
  final int basePaidAmountMinor;
  final int baseCostTotalMinor;

  final DocumentStatus status;
  final int? cashSessionId;
  final int? userId;
  final String? notes;
  final String createdAtStorage;
  final String updatedAtStorage;
  final List<SaleLine> lines;
  final List<SalePayment> payments;

  Money get total => Money(totalMinor, decimalDigits: currencyDecimalDigits);
  Money get paid => Money(paidAmountMinor, decimalDigits: currencyDecimalDigits);

  /// Outstanding amount in the sale currency, never negative.
  Money get outstanding {
    final due = totalMinor - paidAmountMinor;
    return Money(due < 0 ? 0 : due, decimalDigits: currencyDecimalDigits);
  }

  /// Outstanding amount in base-currency minor units, converted with the rate
  /// stored on this invoice rather than today's rate.
  int get baseOutstandingMinor {
    final due = baseTotalMinor - basePaidAmountMinor;
    return due < 0 ? 0 : due;
  }

  /// Gross profit in base-currency minor units.
  ///
  /// The invoice discount reduces revenue without reducing the cost of the goods
  /// sold, so it is already reflected in `baseTotalMinor`.
  int get grossProfitMinor => baseTotalMinor - baseCostTotalMinor;

  bool get isFullyPaid => paidAmountMinor >= totalMinor;
  bool get isCredit => baseOutstandingMinor > 0;
  bool get isPosted => status == DocumentStatus.posted;
  bool get isVoided => status == DocumentStatus.voided;

  /// Total quantity across all lines, for a receipt summary.
  int get totalQuantityScaled =>
      lines.fold<int>(0, (sum, line) => sum + line.quantityScaled);
}

/// A sale being assembled in the POS screen, before it is posted.
///
/// This is a domain object rather than widget state so the arithmetic the cashier
/// sees is the same arithmetic the repository persists. The checkout screen
/// renders [SaleDraft.total] and the repository recomputes the totals from the
/// same lines, so a UI bug cannot produce an invoice that disagrees with the
/// amount that was displayed.
class SaleDraft {
  const SaleDraft({
    required this.currencyId,
    required this.currencyDecimalDigits,
    this.customerId,
    this.lines = const <SaleLine>[],
    this.invoiceDiscountMinor = 0,
    this.exchangeRateNumerator = 1,
    this.exchangeRateDenominator = 1,
    this.notes,
  });

  final int currencyId;
  final int currencyDecimalDigits;
  final int? customerId;
  final List<SaleLine> lines;
  final int invoiceDiscountMinor;

  /// Rate from the sale currency to the base currency.
  final int exchangeRateNumerator;
  final int exchangeRateDenominator;

  final String? notes;

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  /// The invoice subtotal: the sum of the lines after their own discounts.
  int get subtotalMinor =>
      lines.fold<int>(0, (sum, line) => sum + line.netMinor);

  /// The sum of the per-line discounts, reported separately on the invoice.
  int get lineDiscountTotalMinor =>
      lines.fold<int>(0, (sum, line) => sum + line.lineDiscountMinor);

  /// Cost of goods sold for the whole draft, in base-currency minor units.
  int get costTotalMinor =>
      lines.fold<int>(0, (sum, line) => sum + line.costMinor);

  /// The invoice total after the invoice-level discount, never negative.
  int get totalMinor {
    final value = subtotalMinor - invoiceDiscountMinor;
    return value < 0 ? 0 : value;
  }

  /// The total converted to base-currency minor units using this draft's rate.
  int get baseTotalMinor =>
      mulDivRound(totalMinor, exchangeRateNumerator, exchangeRateDenominator);

  Money get total => Money(totalMinor, decimalDigits: currencyDecimalDigits);

  /// Finds the line for a product, or null when it is not in the cart.
  SaleLine? lineFor(int productId) {
    for (final line in lines) {
      if (line.productId == productId) return line;
    }
    return null;
  }

  /// Adds a product, merging into the existing line when it is already present.
  ///
  /// Merging is what a cashier expects when the same item is scanned twice, and
  /// it keeps the receipt readable. The existing line's price and cost are kept,
  /// so a mid-sale price change cannot silently re-price an item already in the
  /// cart.
  SaleDraft addLine(SaleLine line) {
    final existing = lineFor(line.productId);
    if (existing == null) {
      return copyWith(lines: <SaleLine>[...lines, line]);
    }
    final merged = existing.copyWith(
      quantityScaled: existing.quantityScaled + line.quantityScaled,
    );
    return copyWith(
      lines: <SaleLine>[
        for (final current in lines)
          if (current.productId == line.productId) merged else current,
      ],
    );
  }

  /// Sets a line's quantity, removing the line when the quantity reaches zero.
  SaleDraft setQuantity(int productId, int quantityScaled) {
    if (quantityScaled <= 0) return removeLine(productId);
    return copyWith(
      lines: <SaleLine>[
        for (final line in lines)
          if (line.productId == productId)
            line.copyWith(quantityScaled: quantityScaled)
          else
            line,
      ],
    );
  }

  /// Removes a product from the cart.
  SaleDraft removeLine(int productId) => copyWith(
        lines: <SaleLine>[
          for (final line in lines)
            if (line.productId != productId) line,
        ],
      );

  /// Applies a discount to one line.
  SaleDraft setLineDiscount(int productId, int discountMinor) => copyWith(
        lines: <SaleLine>[
          for (final line in lines)
            if (line.productId == productId)
              line.copyWith(
                lineDiscountMinor: discountMinor < 0 ? 0 : discountMinor,
              )
            else
              line,
        ],
      );

  SaleDraft copyWith({
    int? currencyId,
    int? currencyDecimalDigits,
    int? customerId,
    List<SaleLine>? lines,
    int? invoiceDiscountMinor,
    int? exchangeRateNumerator,
    int? exchangeRateDenominator,
    String? notes,
    bool clearCustomer = false,
  }) {
    return SaleDraft(
      currencyId: currencyId ?? this.currencyId,
      currencyDecimalDigits:
          currencyDecimalDigits ?? this.currencyDecimalDigits,
      customerId: clearCustomer ? null : (customerId ?? this.customerId),
      lines: lines ?? this.lines,
      invoiceDiscountMinor: invoiceDiscountMinor ?? this.invoiceDiscountMinor,
      exchangeRateNumerator: exchangeRateNumerator ?? this.exchangeRateNumerator,
      exchangeRateDenominator:
          exchangeRateDenominator ?? this.exchangeRateDenominator,
      notes: notes ?? this.notes,
    );
  }
}
