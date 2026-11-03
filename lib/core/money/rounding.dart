/// Rounding policies used by every monetary and quantity operation.
///
/// StoreFlow never uses `double` for money or stock quantities. All arithmetic
/// is performed on integers (with `BigInt` intermediates where a product could
/// overflow) and reduced back to integers through one of these policies.
library;

/// How a division remainder is resolved when reducing an exact rational result
/// back to an integer number of minor units.
enum RoundingMode {
  /// Round half away from zero: 0.5 -> 1, -0.5 -> -1. Retail default.
  halfUp,

  /// Round half towards zero: 0.5 -> 0, -0.5 -> 0.
  halfDown,

  /// Truncate towards zero.
  down,

  /// Round away from zero.
  up,
}

/// Computes `(a * b) / d` using exact integer arithmetic and the given
/// [RoundingMode]. `BigInt` is used for the intermediate product so that large
/// totals cannot silently overflow a 64-bit integer.
int mulDivRound(int a, int b, int d, {RoundingMode mode = RoundingMode.halfUp}) {
  if (d == 0) {
    throw ArgumentError.value(d, 'd', 'Division by zero in mulDivRound');
  }
  final product = BigInt.from(a) * BigInt.from(b);
  return _reduce(product, BigInt.from(d), mode);
}

/// Computes `n / d` with the given [RoundingMode] using exact arithmetic.
int divRound(int n, int d, {RoundingMode mode = RoundingMode.halfUp}) {
  if (d == 0) {
    throw ArgumentError.value(d, 'd', 'Division by zero in divRound');
  }
  return _reduce(BigInt.from(n), BigInt.from(d), mode);
}

int _reduce(BigInt numerator, BigInt denominator, RoundingMode mode) {
  final negative = numerator.isNegative != denominator.isNegative;
  final n = numerator.abs();
  final d = denominator.abs();
  final quotient = n ~/ d;
  final remainder = n.remainder(d);
  if (remainder == BigInt.zero) {
    final q = quotient.toInt();
    return negative ? -q : q;
  }
  BigInt rounded;
  switch (mode) {
    case RoundingMode.down:
      rounded = quotient;
    case RoundingMode.up:
      rounded = quotient + BigInt.one;
    case RoundingMode.halfUp:
    case RoundingMode.halfDown:
      final twice = remainder * BigInt.two;
      if (twice > d) {
        rounded = quotient + BigInt.one;
      } else if (twice < d) {
        rounded = quotient;
      } else {
        rounded =
            mode == RoundingMode.halfUp ? quotient + BigInt.one : quotient;
      }
  }
  final value = rounded.toInt();
  return negative ? -value : value;
}

/// Returns `10^exponent` as an integer.
int pow10(int exponent) {
  var result = 1;
  for (var i = 0; i < exponent; i++) {
    result *= 10;
  }
  return result;
}
