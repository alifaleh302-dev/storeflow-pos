import 'money.dart';
import 'rounding.dart';

/// An exact exchange rate expressed as the rational `numerator / denominator`.
///
/// ## Documented conversion direction
///
/// The rate converts *minor units of the transaction currency* into *minor
/// units of the base currency*:
///
/// ```
/// base_minor = round(tx_minor * numerator / denominator)
/// ```
///
/// So `numerator / denominator` is "base-currency minor units per one
/// transaction-currency minor unit". Because both sides are minor units, the
/// rate implicitly encodes the difference in currency precision and no extra
/// scaling step is needed.
///
/// ### Worked example
///
/// Base currency SAR (2 decimal digits), transaction currency USD
/// (2 decimal digits), market rate 1 USD = 3.75 SAR.
///
/// * One USD minor unit is 0.01 USD = 0.0375 SAR = 3.75 SAR minor units.
/// * Therefore `numerator = 15`, `denominator = 4`.
/// * Converting 10.00 USD (1000 USD minor units) yields
///   `round(1000 * 15 / 4) = 3750` SAR minor units = 37.50 SAR. Correct.
///
/// The base currency itself always uses the identity rate `1/1`.
///
/// A rate is stored on every posted transaction so that later changes to the
/// configured rate never rewrite history.
class ExchangeRate {
  /// Creates a rate, normalising the sign so the denominator stays positive.
  factory ExchangeRate({required int numerator, required int denominator}) {
    if (denominator == 0) {
      throw ArgumentError.value(denominator, 'denominator', 'Must not be zero');
    }
    if (numerator == 0) {
      throw ArgumentError.value(numerator, 'numerator', 'Must not be zero');
    }
    if (denominator < 0) {
      return ExchangeRate._(-numerator, -denominator);
    }
    return ExchangeRate._(numerator, denominator);
  }

  const ExchangeRate._(this.numerator, this.denominator);

  /// Identity rate used for the base currency.
  static const ExchangeRate identity = ExchangeRate._(1, 1);

  /// Signed numerator of the rational rate.
  final int numerator;

  /// Positive denominator of the rational rate.
  final int denominator;

  bool get isIdentity => numerator == denominator;

  /// Converts [amount] in the transaction currency to the base currency.
  ///
  /// Rounding is applied once, at the end of the conversion, with [mode].
  Money toBase(Money amount, {RoundingMode mode = RoundingMode.halfUp}) {
    return Money(
      mulDivRound(amount.minorUnits, numerator, denominator, mode: mode),
      decimalDigits: amount.decimalDigits,
    );
  }

  /// Converts a base-currency [amount] back into the transaction currency.
  ///
  /// This is the exact inverse of [toBase] except for rounding, which is why
  /// reports must always read stored amounts rather than recomputing them.
  Money fromBase(Money amount, {RoundingMode mode = RoundingMode.halfUp}) {
    return Money(
      mulDivRound(amount.minorUnits, denominator, numerator, mode: mode),
      decimalDigits: amount.decimalDigits,
    );
  }

  /// The rate as a decimal string with [fractionDigits] places, for display.
  String toDecimalString({int fractionDigits = 6}) {
    final scaled =
        mulDivRound(numerator, pow10(fractionDigits), denominator, mode: RoundingMode.halfDown);
    final negative = scaled < 0;
    final abs = scaled.abs();
    final whole = abs ~/ pow10(fractionDigits);
    final fraction = abs % pow10(fractionDigits);
    final body =
        '${negative ? '-' : ''}$whole.${fraction.toString().padLeft(fractionDigits, '0')}';
    // Trim trailing zeros but keep at least one fraction digit.
    final trimmed = body.contains('.')
        ? body.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '.0')
        : body;
    return trimmed;
  }

  @override
  bool operator ==(Object other) =>
      other is ExchangeRate &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => '$numerator/$denominator';
}
