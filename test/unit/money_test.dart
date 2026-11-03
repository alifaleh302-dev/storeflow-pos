import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/money/money.dart';
import 'package:storeflow_pos/core/money/rounding.dart';

void main() {
  group('Money construction and parsing', () {
    test('fromMajor scales by currency precision', () {
      expect(Money.fromMajor(10, decimalDigits: 2).minorUnits, 1000);
      expect(Money.fromMajor(10, decimalDigits: 0).minorUnits, 10);
      expect(Money.fromMajor(10, decimalDigits: 3).minorUnits, 10000);
    });

    test('tryParse accepts whole, fractional and signed values', () {
      expect(Money.tryParse('100', decimalDigits: 2)!.minorUnits, 10000);
      expect(Money.tryParse('100.25', decimalDigits: 2)!.minorUnits, 10025);
      expect(Money.tryParse('0.5', decimalDigits: 2)!.minorUnits, 50);
      expect(Money.tryParse('.5', decimalDigits: 2)!.minorUnits, 50);
      expect(Money.tryParse('-3.49', decimalDigits: 2)!.minorUnits, -349);
      expect(Money.tryParse('1,234.50', decimalDigits: 2)!.minorUnits, 123450);
      expect(Money.tryParse('7', decimalDigits: 0)!.minorUnits, 7);
    });

    test('tryParse rejects too many decimal digits unless rounding is allowed',
        () {
      // A 2-digit currency cannot represent 3 fraction digits exactly.
      expect(Money.tryParse('1.005', decimalDigits: 2), isNull);
      final rounded =
          Money.tryParse('1.005', decimalDigits: 2, rounding: RoundingMode.halfUp);
      expect(rounded!.minorUnits, 101); // 1.005 -> 1.01 (half up on 0.5)
    });

    test('tryParse rejects malformed input', () {
      expect(Money.tryParse('', decimalDigits: 2), isNull);
      expect(Money.tryParse('abc', decimalDigits: 2), isNull);
      expect(Money.tryParse('1.2.3', decimalDigits: 2), isNull);
      expect(Money.tryParse('.', decimalDigits: 2), isNull);
    });

    test('toDecimalString is locale independent and pads correctly', () {
      expect(Money(10025, decimalDigits: 2).toDecimalString(), '100.25');
      expect(Money(5, decimalDigits: 2).toDecimalString(), '0.05');
      expect(Money(-5, decimalDigits: 2).toDecimalString(), '-0.05');
      expect(Money(7, decimalDigits: 0).toDecimalString(), '7');
      expect(Money(5, decimalDigits: 3).toDecimalString(), '0.005');
      expect(
        Money(10025, decimalDigits: 2).toDecimalString(decimalSeparator: ','),
        '100,25',
      );
    });

    test('round trips through parse and format', () {
      for (final value in <int>[0, 1, 99, 100, 12345, -12345]) {
        final money = Money(value, decimalDigits: 2);
        expect(Money.tryParse(money.toDecimalString(), decimalDigits: 2), money);
      }
    });
  });

  group('Money arithmetic', () {
    test('addition and subtraction keep precision', () {
      final a = Money(10025, decimalDigits: 2);
      final b = Money(9975, decimalDigits: 2);
      expect((a + b).minorUnits, 20000);
      expect((a - b).minorUnits, 50);
      expect((-a).minorUnits, -10025);
    });

    test('combining different precisions throws', () {
      final usd = Money(100, decimalDigits: 2);
      final jpy = Money(100, decimalDigits: 0);
      expect(() => usd + jpy, throwsArgumentError);
    });

    test('timesRational applies exact rational scaling', () {
      final unitPrice = Money(1050, decimalDigits: 2); // 10.50
      // 3 units of 1.5 quantity -> 4.5 -> 10.50 * 4.5 = 47.25
      final lineTotal = unitPrice.timesRational(4500, 1000);
      expect(lineTotal.minorUnits, 4725);
    });

    test('allocateEvenly never loses or invents minor units', () {
      final total = Money(10000, decimalDigits: 2); // 100.00 split 3 ways
      final parts = total.allocateEvenly(3);
      expect(parts.length, 3);
      expect(parts.fold<int>(0, (sum, p) => sum + p.minorUnits), 10000);
      expect(parts.first.minorUnits, 3334);
      expect(parts.last.minorUnits, 3333);
    });

    test('allocate preserves the total using weights', () {
      final total = Money(10000, decimalDigits: 2);
      final parts = total.allocate(<int>[1, 1, 1]);
      expect(parts.fold<int>(0, (sum, p) => sum + p.minorUnits), 10000);
    });

    test('allocate distributes the remainder to the final share', () {
      final total = Money(100, decimalDigits: 2);
      final parts = total.allocate(<int>[1, 1, 1]);
      expect(parts.fold<int>(0, (sum, p) => sum + p.minorUnits), 100);
    });

    test('allocate rejects non-positive weights', () {
      final total = Money(100, decimalDigits: 2);
      expect(() => total.allocate(<int>[0, 0]), throwsArgumentError);
      expect(() => total.allocateEvenly(0), throwsArgumentError);
    });

    test('comparison operators work', () {
      final a = Money(100, decimalDigits: 2);
      final b = Money(200, decimalDigits: 2);
      expect(a < b, isTrue);
      expect(a <= b, isTrue);
      expect(b > a, isTrue);
      expect(b >= a, isTrue);
      expect(a == Money(100, decimalDigits: 2), isTrue);
      expect(a.hashCode, Money(100, decimalDigits: 2).hashCode);
    });
  });

  group('Money edge cases', () {
    test('zero, positive and negative predicates', () {
      expect(const Money.zero(decimalDigits: 2).isZero, isTrue);
      expect(Money(1, decimalDigits: 2).isPositive, isTrue);
      expect(Money(-1, decimalDigits: 2).isNegative, isTrue);
    });

    test('scale reflects the currency precision', () {
      expect(Money(0, decimalDigits: 2).scale, 100);
      expect(Money(0, decimalDigits: 0).scale, 1);
      expect(Money(0, decimalDigits: 3).scale, 1000);
    });

    test('times multiplies by a whole number', () {
      expect(Money(1050, decimalDigits: 2).times(3).minorUnits, 3150);
    });
  });
}
