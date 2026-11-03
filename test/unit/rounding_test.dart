import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/money/rounding.dart';

void main() {
  group('mulDivRound', () {
    test('returns exact results when the division is clean', () {
      expect(mulDivRound(100, 3, 4), 75);
      expect(mulDivRound(0, 999, 7), 0);
    });

    test('rounds half away from zero for positive values', () {
      // 1 * 1 / 2 = 0.5 -> 1
      expect(mulDivRound(1, 1, 2), 1);
      // 3 * 1 / 2 = 1.5 -> 2
      expect(mulDivRound(3, 1, 2), 2);
      // 1 * 1 / 4 = 0.25 -> 0
      expect(mulDivRound(1, 1, 4), 0);
      // 3 * 1 / 4 = 0.75 -> 1
      expect(mulDivRound(3, 1, 4), 1);
    });

    test('rounds half away from zero for negative values', () {
      expect(mulDivRound(-1, 1, 2), -1);
      expect(mulDivRound(-3, 1, 2), -2);
      expect(mulDivRound(-1, 1, 4), 0);
      expect(mulDivRound(-3, 1, 4), -1);
    });

    test('honours down and up modes', () {
      expect(mulDivRound(7, 1, 2, mode: RoundingMode.down), 3);
      expect(mulDivRound(7, 1, 2, mode: RoundingMode.up), 4);
      expect(mulDivRound(-7, 1, 2, mode: RoundingMode.down), -3);
      expect(mulDivRound(-7, 1, 2, mode: RoundingMode.up), -4);
    });

    test('honours halfDown mode', () {
      expect(mulDivRound(1, 1, 2, mode: RoundingMode.halfDown), 0);
      expect(mulDivRound(3, 1, 2, mode: RoundingMode.halfDown), 1);
      expect(mulDivRound(-1, 1, 2, mode: RoundingMode.halfDown), 0);
    });

    test('does not overflow for large products', () {
      // 2^40 * 2^40 would overflow a 64-bit int; BigInt intermediates keep it
      // exact, and the result is still a representable int.
      const big = 1 << 40;
      expect(mulDivRound(big, big, big), big);
    });

    test('throws on division by zero', () {
      expect(() => mulDivRound(1, 1, 0), throwsArgumentError);
      expect(() => divRound(1, 0), throwsArgumentError);
    });
  });

  group('pow10', () {
    test('computes powers of ten', () {
      expect(pow10(0), 1);
      expect(pow10(1), 10);
      expect(pow10(2), 100);
      expect(pow10(3), 1000);
    });
  });
}
