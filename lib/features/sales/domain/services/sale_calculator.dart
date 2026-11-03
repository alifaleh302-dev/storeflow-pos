import '../../../../core/constants/enums.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/money/money.dart';
import '../../../../core/money/rounding.dart';
import '../entities/sale.dart';

/// The result of checking a draft against the stock that is actually available.
class SaleValidationResult {
  const SaleValidationResult({required this.shortages, required this.errors});

  /// Lines whose requested quantity exceeds what is on hand.
  final List<StockShortage> shortages;

  /// Structural problems that make the draft unsellable.
  final List<String> errors;

  bool get isValid => shortages.isEmpty && errors.isEmpty;

  static const SaleValidationResult valid =
      SaleValidationResult(shortages: <StockShortage>[], errors: <String>[]);
}

/// A line that cannot be fulfilled.
class StockShortage {
  const StockShortage({
    required this.productId,
    required this.productName,
    required this.availableScaled,
    required this.requestedScaled,
  });

  final int productId;
  final String productName;
  final int availableScaled;
  final int requestedScaled;

  int get missingScaled => requestedScaled - availableScaled;
}

/// One tender as it will be recorded.
class PaymentAllocation {
  const PaymentAllocation({
    required this.paymentMethod,
    required this.currencyId,
    required this.amountMinor,
    required this.exchangeRateNumerator,
    required this.exchangeRateDenominator,
    required this.baseAmountMinor,
    this.notes,
  });

  final PaymentMethod paymentMethod;
  final int currencyId;
  final int amountMinor;
  final int exchangeRateNumerator;
  final int exchangeRateDenominator;
  final int baseAmountMinor;
  final String? notes;
}

/// Pure validation and arithmetic for a checkout.
///
/// Kept out of the repository so every rule about what makes a sale legal can be
/// unit-tested on the Dart VM, and so the POS screen can explain a rejection
/// before the cashier presses confirm rather than after.
abstract final class SaleCalculator {
  /// Checks a draft for structural problems and stock shortages.
  ///
  /// [availableByProduct] maps a product id to the quantity on hand, scaled.
  /// A product absent from the map is treated as zero on hand, which is correct:
  /// a product that has never moved stock has none.
  static SaleValidationResult validate({
    required SaleDraft draft,
    required Map<int, int> availableByProduct,
    required bool allowNegativeStock,
  }) {
    final errors = <String>[];
    final shortages = <StockShortage>[];

    if (draft.isEmpty) {
      errors.add('empty_cart');
    }
    if (draft.totalMinor < 0) {
      errors.add('negative_total');
    }
    if (draft.invoiceDiscountMinor < 0) {
      errors.add('negative_discount');
    }
    if (draft.invoiceDiscountMinor > draft.subtotalMinor) {
      errors.add('discount_exceeds_subtotal');
    }
    for (final line in draft.lines) {
      if (line.quantityScaled <= 0) {
        errors.add('non_positive_quantity');
        break;
      }
      if (line.lineDiscountMinor < 0) {
        errors.add('negative_line_discount');
        break;
      }
      if (line.lineDiscountMinor > line.grossMinor) {
        errors.add('line_discount_exceeds_line');
        break;
      }
    }

    if (!allowNegativeStock) {
      for (final line in draft.lines) {
        final available = availableByProduct[line.productId] ?? 0;
        if (line.quantityScaled > available) {
          shortages.add(
            StockShortage(
              productId: line.productId,
              productName: line.productName,
              availableScaled: available,
              requestedScaled: line.quantityScaled,
            ),
          );
        }
      }
    }

    return SaleValidationResult(shortages: shortages, errors: errors);
  }

  /// The amount still to be paid, in the sale's currency, never negative.
  static int outstandingMinor({required int totalMinor, required int paidMinor}) {
    final due = totalMinor - paidMinor;
    return due < 0 ? 0 : due;
  }

  /// Converts a tender in [currencyId] into base-currency minor units.
  ///
  /// Each tender converts with its own currency's rate, so a split payment across
  /// two currencies records two independent conversions rather than one blended
  /// figure.
  static int toBaseMinor({
    required int amountMinor,
    required int rateNumerator,
    required int rateDenominator,
  }) {
    if (rateNumerator <= 0 || rateDenominator <= 0) {
      throw ValidationFailure(
        'Invalid exchange rate',
        field: 'exchangeRate',
        details: <String, Object?>{
          'numerator': rateNumerator,
          'denominator': rateDenominator,
        },
      );
    }
    return mulDivRound(amountMinor, rateNumerator, rateDenominator);
  }

  /// Converts a base-currency amount back into a transaction currency.
  ///
  /// The inverse of [toBaseMinor], used to express how much money was received in
  /// the invoice's own currency when some tenders arrived in another one.
  static int fromBaseMinor({
    required int baseMinor,
    required int rateNumerator,
    required int rateDenominator,
  }) {
    if (rateNumerator <= 0 || rateDenominator <= 0) {
      throw ValidationFailure(
        'Invalid exchange rate',
        field: 'exchangeRate',
        details: <String, Object?>{
          'numerator': rateNumerator,
          'denominator': rateDenominator,
        },
      );
    }
    return mulDivRound(baseMinor, rateDenominator, rateNumerator);
  }

  /// Checks that the tenders settle the invoice without overpaying it.
  ///
  /// Money actually handed over and credit are counted separately, because they
  /// are not the same thing. A credit tender is a promise to pay later: it closes
  /// the invoice but it must never be reported as cash collected or added to the
  /// drawer. Only the money portion is capped at the invoice total, so a customer
  /// cannot hand over more than the price while a credit line covers the rest.
  /// Everything is compared in the base currency. A tender in a foreign currency
  /// carries its own minor units, so summing raw amounts across currencies would
  /// compare dollars against riyals; each allocation's [PaymentAllocation
  /// .baseAmountMinor] is what makes the comparison meaningful.
  static void assertSettles({
    required int baseTotalMinor,
    required List<PaymentAllocation> allocations,
  }) {
    if (allocations.isEmpty) {
      throw const ValidationFailure(
        'A sale needs at least one payment',
        field: 'payments',
      );
    }
    var money = 0;
    var credit = 0;
    for (final allocation in allocations) {
      if (allocation.amountMinor < 0 || allocation.baseAmountMinor < 0) {
        throw const ValidationFailure(
          'A payment cannot be negative',
          field: 'payments',
        );
      }
      if (allocation.paymentMethod.isCredit) {
        credit += allocation.baseAmountMinor;
      } else {
        money += allocation.baseAmountMinor;
      }
    }
    if (money > baseTotalMinor) {
      throw ValidationFailure(
        'Payment exceeds the invoice total',
        field: 'payments',
        details: <String, Object?>{
          'baseTotalMinor': baseTotalMinor,
          'moneyBaseMinor': money,
        },
      );
    }
    if (money + credit < baseTotalMinor) {
      throw ValidationFailure(
        'Payment does not cover the invoice total',
        field: 'payments',
        details: <String, Object?>{
          'baseTotalMinor': baseTotalMinor,
          'moneyBaseMinor': money,
          'creditBaseMinor': credit,
        },
      );
    }
  }

  /// Splits an invoice discount across the lines, in proportion to their value.
  ///
  /// Reports need to attribute a discount to products, and a proportional split
  /// with the remainder allocated one minor unit at a time is the only way to do
  /// that without either losing or inventing money.
  static List<int> allocateInvoiceDiscount({
    required List<int> lineValues,
    required int discountMinor,
  }) {
    if (lineValues.isEmpty || discountMinor == 0) {
      return List<int>.filled(lineValues.length, 0);
    }
    final total = lineValues.fold<int>(0, (sum, value) => sum + value);
    if (total <= 0) return List<int>.filled(lineValues.length, 0);

    final shares = <int>[];
    var allocated = 0;
    for (var i = 0; i < lineValues.length; i++) {
      if (i == lineValues.length - 1) {
        shares.add(discountMinor - allocated);
      } else {
        final share = mulDivRound(discountMinor, lineValues[i], total,
            mode: RoundingMode.down);
        shares.add(share);
        allocated += share;
      }
    }
    return shares;
  }

  /// Builds a money value in the draft's currency.
  static Money money(int minorUnits, SaleDraft draft) =>
      Money(minorUnits, decimalDigits: draft.currencyDecimalDigits);
}
