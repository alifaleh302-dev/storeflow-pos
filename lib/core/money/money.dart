import 'rounding.dart';

/// An exact monetary amount expressed as an integer number of minor units.
///
/// A currency with [decimalDigits] == 2 stores 100.25 as 10025. A currency with
/// 0 digits stores 100 as 100. Amounts are never represented as `double`.
///
/// [Money] carries the currency precision so that arithmetic between two
/// amounts of the same currency keeps a consistent scale. Cross-currency
/// arithmetic is deliberately unsupported here: it must go through an explicit
/// exchange-rate conversion so the rate actually used is recorded.
class Money implements Comparable<Money> {
  const Money(this.minorUnits, {required this.decimalDigits});

  /// Creates a zero amount for a currency with the given precision.
  const Money.zero({required this.decimalDigits}) : minorUnits = 0;

  /// The signed amount in minor units (for example cents).
  final int minorUnits;

  /// Number of decimal digits the currency uses for display and storage.
  final int decimalDigits;

  bool get isZero => minorUnits == 0;
  bool get isNegative => minorUnits < 0;
  bool get isPositive => minorUnits > 0;

  /// The scale factor of this currency, e.g. 100 for a 2-digit currency.
  int get scale => pow10(decimalDigits);

  /// Builds an amount from a whole major-unit integer, e.g. `fromMajor(10)` is
  /// 1000 minor units for a 2-digit currency.
  factory Money.fromMajor(int majorUnits, {required int decimalDigits}) {
    return Money(majorUnits * pow10(decimalDigits),
        decimalDigits: decimalDigits);
  }

  /// Parses a user-entered decimal string such as `"12.5"` or `"-3.499"`.
  ///
  /// Extra fractional digits beyond the currency precision are rejected by
  /// default so a typo cannot silently lose money. Pass [rounding] to accept
  /// and round instead.
  static Money? tryParse(
    String input, {
    required int decimalDigits,
    RoundingMode? rounding,
  }) {
    final text = input.trim().replaceAll(',', '');
    if (text.isEmpty) return null;
    final match = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?$').firstMatch(text);
    if (match == null) return null;
    final sign = match.group(1) == '-' ? -1 : 1;
    final whole = match.group(2) ?? '';
    final fraction = match.group(3) ?? '';
    if (whole.isEmpty && fraction.isEmpty) return null;
    if (fraction.length > decimalDigits && rounding == null) return null;

    final scale = pow10(decimalDigits);
    final wholeValue = whole.isEmpty ? BigInt.zero : BigInt.parse(whole);
    var minor = wholeValue * BigInt.from(scale);

    final effective =
        fraction.length > decimalDigits ? fraction.substring(0, decimalDigits) : fraction;
    if (effective.isNotEmpty) {
      minor += BigInt.parse(effective.padRight(decimalDigits, '0'));
    }
    var value = minor.toInt() * sign;

    if (fraction.length > decimalDigits) {
      // The dropped digits are a fraction of 10^(fraction.length), not of
      // 10^(dropped.length): "1.005" drops "5", which is 5/1000 of a unit.
      final dropped = fraction.substring(decimalDigits);
      final fractionValue = int.parse(dropped);
      final unit = pow10(fraction.length);
      value += sign *
          mulDivRound(fractionValue, scale, unit,
              mode: rounding ?? RoundingMode.halfUp);
    }
    return Money(value, decimalDigits: decimalDigits);
  }

  Money operator +(Money other) {
    _assertSameScale(other);
    return Money(minorUnits + other.minorUnits, decimalDigits: decimalDigits);
  }

  Money operator -(Money other) {
    _assertSameScale(other);
    return Money(minorUnits - other.minorUnits, decimalDigits: decimalDigits);
  }

  Money operator -() => Money(-minorUnits, decimalDigits: decimalDigits);

  /// Multiplies by a whole number, for example a line count.
  Money times(int factor) =>
      Money(minorUnits * factor, decimalDigits: decimalDigits);

  /// Multiplies by an exact rational factor `numerator / denominator`, rounding
  /// the result with [mode]. Used for quantity extension and proration.
  Money timesRational(
    int numerator,
    int denominator, {
    RoundingMode mode = RoundingMode.halfUp,
  }) {
    return Money(
      mulDivRound(minorUnits, numerator, denominator, mode: mode),
      decimalDigits: decimalDigits,
    );
  }

  /// Splits this amount into [parts] portions whose sum is exactly this amount.
  ///
  /// Any remainder is distributed one minor unit at a time, so no value is ever
  /// lost to rounding.
  List<Money> allocateEvenly(int parts) {
    if (parts <= 0) {
      throw ArgumentError.value(parts, 'parts', 'Must be greater than zero');
    }
    final base = minorUnits ~/ parts;
    var remainder = minorUnits - base * parts;
    final step = remainder.isNegative ? -1 : 1;
    final result = <Money>[];
    for (var i = 0; i < parts; i++) {
      var value = base;
      if (remainder != 0) {
        value += step;
        remainder -= step;
      }
      result.add(Money(value, decimalDigits: decimalDigits));
    }
    return result;
  }

  /// Splits this amount according to integer [weights], preserving the total.
  List<Money> allocate(List<int> weights) {
    final totalWeight = weights.fold<int>(0, (sum, w) => sum + w);
    if (totalWeight <= 0) {
      throw ArgumentError.value(weights, 'weights', 'Weights must sum to > 0');
    }
    final result = <Money>[];
    var allocated = 0;
    for (var i = 0; i < weights.length; i++) {
      if (i == weights.length - 1) {
        result.add(Money(minorUnits - allocated, decimalDigits: decimalDigits));
      } else {
        final share = mulDivRound(minorUnits, weights[i], totalWeight,
            mode: RoundingMode.down);
        result.add(Money(share, decimalDigits: decimalDigits));
        allocated += share;
      }
    }
    return result;
  }

  /// Formats the amount as `sign + whole + separator + fraction` with
  /// [decimalDigits] fraction digits, independent of locale.
  String toDecimalString({String? decimalSeparator}) {
    final sep = decimalSeparator ?? '.';
    final negative = minorUnits < 0;
    final abs = minorUnits.abs();
    final scale = pow10(decimalDigits);
    final whole = abs ~/ scale;
    final fraction = abs % scale;
    final buffer = StringBuffer();
    if (negative) buffer.write('-');
    buffer.write(whole);
    if (decimalDigits > 0) {
      buffer.write(sep);
      buffer.write(fraction.toString().padLeft(decimalDigits, '0'));
    }
    return buffer.toString();
  }

  @override
  int compareTo(Money other) {
    _assertSameScale(other);
    return minorUnits.compareTo(other.minorUnits);
  }

  bool operator >(Money other) => compareTo(other) > 0;
  bool operator >=(Money other) => compareTo(other) >= 0;
  bool operator <(Money other) => compareTo(other) < 0;
  bool operator <=(Money other) => compareTo(other) <= 0;

  void _assertSameScale(Money other) {
    if (other.decimalDigits != decimalDigits) {
      throw ArgumentError(
        'Cannot combine amounts with different precision: '
        '$decimalDigits vs ${other.decimalDigits}',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Money &&
      other.minorUnits == minorUnits &&
      other.decimalDigits == decimalDigits;

  @override
  int get hashCode => Object.hash(minorUnits, decimalDigits);

  @override
  String toString() => '${toDecimalString()} [${pow10(decimalDigits)}]';
}
