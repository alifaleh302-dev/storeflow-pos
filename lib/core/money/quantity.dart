import 'rounding.dart';

/// An exact inventory quantity stored as a scaled integer.
///
/// ## Documented quantity scale
///
/// Every quantity in StoreFlow is an integer multiplied by a fixed scale of
/// **1000** (`Quantity.scale`). A quantity of `1.5` kg is stored as `1500`.
/// This gives three decimal places of precision, which is enough for
/// fractional retail units (kg, litre, metre) while remaining an exact integer.
///
/// The scale is a single global constant so that stock balances, ledger
/// movements and line items are directly comparable without per-row metadata.
/// When a unit's `quantityPrecision` is lower than 3, the extra digits are
/// simply unused.
///
/// Quantities are never stored as `double`.
class Quantity implements Comparable<Quantity> {
  const Quantity(this.scaledValue);

  /// The single global quantity scale: 1 unit == 1000 scaled units.
  static const int scale = 1000;

  /// Number of decimal digits of precision implied by [scale].
  static const int decimalDigits = 3;

  static const Quantity zero = Quantity(0);

  /// The raw integer value: real quantity multiplied by [scale].
  final int scaledValue;

  bool get isZero => scaledValue == 0;
  bool get isNegative => scaledValue < 0;
  bool get isPositive => scaledValue > 0;

  /// Builds a quantity from whole and fractional parts, e.g. `fromParts(1, 500)`
  /// is `1.5` (since 500 / 1000).
  factory Quantity.fromParts(int whole, [int scaledFraction = 0]) {
    final sign = whole < 0 ? -1 : 1;
    return Quantity(whole * scale + sign * scaledFraction);
  }

  /// Parses a decimal string such as `"1.5"` or `"-0.25"`. Returns null when the
  /// input is malformed or carries more than three fractional digits.
  static Quantity? tryParse(String input) {
    final text = input.trim().replaceAll(',', '');
    if (text.isEmpty) return null;
    final match = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$').firstMatch(text);
    if (match == null) return null;
    final sign = match.group(1) == '-' ? -1 : 1;
    final whole = match.group(2) ?? '';
    final fraction = match.group(3) ?? '';
    if (whole.isEmpty && fraction.isEmpty) return null;
    if (fraction.length > decimalDigits) return null;
    final wholeValue = whole.isEmpty ? 0 : int.parse(whole);
    final padded = fraction.padRight(decimalDigits, '0');
    final fractionValue = padded.isEmpty ? 0 : int.parse(padded);
    return Quantity(sign * (wholeValue * scale + fractionValue));
  }

  /// The exact decimal value as an integer numerator over [scale].
  int get numerator => scaledValue;

  /// The exact denominator, always [scale].
  int get denominator => scale;

  Quantity operator +(Quantity other) =>
      Quantity(scaledValue + other.scaledValue);

  Quantity operator -(Quantity other) =>
      Quantity(scaledValue - other.scaledValue);

  Quantity operator -() => Quantity(-scaledValue);

  bool operator >(Quantity other) => scaledValue > other.scaledValue;
  bool operator >=(Quantity other) => scaledValue >= other.scaledValue;
  bool operator <(Quantity other) => scaledValue < other.scaledValue;
  bool operator <=(Quantity other) => scaledValue <= other.scaledValue;

  /// Multiplies by a whole number.
  Quantity times(int factor) => Quantity(scaledValue * factor);

  /// Formats the quantity with up to three fraction digits, trimming trailing
  /// zeros (`1500` -> `"1.5"`, `1000` -> `"1"`).
  String toDisplayString({String decimalSeparator = '.'}) {
    final negative = scaledValue < 0;
    final abs = scaledValue.abs();
    final whole = abs ~/ scale;
    final fraction = abs % scale;
    if (fraction == 0) {
      return '${negative ? '-' : ''}$whole';
    }
    var fractionText = fraction.toString().padLeft(decimalDigits, '0');
    fractionText = fractionText.replaceFirst(RegExp(r'0+$'), '');
    return '${negative ? '-' : ''}$whole$decimalSeparator$fractionText';
  }

  @override
  int compareTo(Quantity other) => scaledValue.compareTo(other.scaledValue);

  @override
  bool operator ==(Object other) =>
      other is Quantity && other.scaledValue == scaledValue;

  @override
  int get hashCode => scaledValue.hashCode;

  @override
  String toString() => toDisplayString();
}

/// Multiplies a [Quantity] by a rational unit price expressed in minor units,
/// producing an exact line total in minor units.
///
/// `line_total_minor = round(quantity_scaled * unit_price_minor / Quantity.scale)`
int extendLineTotal(
  Quantity quantity,
  int unitPriceMinor, {
  RoundingMode mode = RoundingMode.halfUp,
}) {
  return mulDivRound(quantity.scaledValue, unitPriceMinor, Quantity.scale,
      mode: mode);
}
