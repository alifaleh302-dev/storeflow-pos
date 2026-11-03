import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/money/exchange_rate.dart';
import 'package:storeflow_pos/core/money/money.dart';
import 'package:storeflow_pos/core/money/rounding.dart';

void main() {
  group('ExchangeRate direction', () {
    test('converts USD to SAR using the documented direction', () {
      // 1 USD = 3.75 SAR, both currencies with 2 decimal digits.
      // One USD minor unit (0.01 USD) is 0.0375 SAR = 3.75 SAR minor units,
      // so numerator/denominator = 15/4.
      final rate = ExchangeRate(numerator: 15, denominator: 4);
      final tenUsd = Money(1000, decimalDigits: 2); // 10.00 USD
      expect(rate.toBase(tenUsd).minorUnits, 3750); // 37.50 SAR
    });

    test('fromBase is the inverse of toBase for exact values', () {
      final rate = ExchangeRate(numerator: 15, denominator: 4);
      final base = Money(3750, decimalDigits: 2);
      expect(rate.fromBase(base).minorUnits, 1000);
    });

    test('identity rate leaves an amount unchanged', () {
      final rate = ExchangeRate(numerator: 1, denominator: 1);
      final amount = Money(12345, decimalDigits: 2);
      expect(rate.toBase(amount).minorUnits, 12345);
      expect(rate.isIdentity, isTrue);
    });

    test('rounding is applied once at the end of the conversion', () {
      // Rate 1/3: 10 minor units -> 10/3 = 3.33 -> 3 with half-up.
      final rate = ExchangeRate(numerator: 1, denominator: 3);
      expect(rate.toBase(Money(10, decimalDigits: 2)).minorUnits, 3);
      // 20/3 = 6.67 -> 7
      expect(rate.toBase(Money(20, decimalDigits: 2)).minorUnits, 7);
    });

    test('supports a currency with fewer decimal digits than the base', () {
      // Base SAR (2 digits), transaction JPY (0 digits).
      // 1 JPY = 0.025 SAR -> one JPY minor unit = 0.025 SAR = 2.5 SAR minor
      // units, so the rate is 5/2.
      final rate = ExchangeRate(numerator: 5, denominator: 2);
      final thousandYen = Money(1000, decimalDigits: 0); // 1000 JPY
      expect(rate.toBase(thousandYen).minorUnits, 2500); // 25.00 SAR
    });
  });

  group('ExchangeRate construction', () {
    test('normalises a negative denominator', () {
      final rate = ExchangeRate(numerator: 3, denominator: -4);
      expect(rate.numerator, -3);
      expect(rate.denominator, 4);
    });

    test('rejects a zero denominator or numerator', () {
      expect(
        () => ExchangeRate(numerator: 1, denominator: 0),
        throwsArgumentError,
      );
      expect(
        () => ExchangeRate(numerator: 0, denominator: 1),
        throwsArgumentError,
      );
    });

    test('equality and hashCode follow the rational value', () {
      expect(
        ExchangeRate(numerator: 15, denominator: 4),
        ExchangeRate(numerator: 15, denominator: 4),
      );
      expect(
        ExchangeRate(numerator: 15, denominator: 4).hashCode,
        ExchangeRate(numerator: 15, denominator: 4).hashCode,
      );
    });
  });

  group('ExchangeRate display', () {
    test('formats a decimal approximation', () {
      expect(
        ExchangeRate(numerator: 15, denominator: 4).toDecimalString(),
        '3.75',
      );
      expect(
        ExchangeRate(numerator: 1, denominator: 1).toDecimalString(),
        '1.0',
      );
    });
  });

  group('Round-trip conversion through history', () {
    test('an invoice keeps its stored rate when the market rate changes', () {
      // Invoice posted when 1 USD = 3.75 SAR.
      final postedRate = ExchangeRate(numerator: 15, denominator: 4);
      final invoiceTotal = Money(1000, decimalDigits: 2);
      final storedBase = postedRate.toBase(invoiceTotal);
      expect(storedBase.minorUnits, 3750);

      // The rate later changes to 3.80 SAR; recomputing with today's rate must
      // give a *different* number, which is exactly why the stored value is
      // authoritative and reports read it instead of recalculating.
      final newRate = ExchangeRate(numerator: 19, denominator: 5);
      final recomputed = newRate.toBase(invoiceTotal);
      expect(recomputed.minorUnits, 3800);
      expect(recomputed, isNot(storedBase));
    });

    test('allocation of a converted amount preserves the total', () {
      final rate = ExchangeRate(numerator: 15, denominator: 4);
      final base = rate.toBase(Money(1000, decimalDigits: 2));
      final parts = base.allocateEvenly(3);
      expect(parts.fold<int>(0, (s, p) => s + p.minorUnits), base.minorUnits);
    });
  });

  group('Rounding modes in conversion', () {
    test('down never over-credits', () {
      final rate = ExchangeRate(numerator: 1, denominator: 3);
      expect(
        rate.toBase(Money(20, decimalDigits: 2), mode: RoundingMode.down).minorUnits,
        6,
      );
    });
  });
}
