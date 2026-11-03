import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/money/quantity.dart';

void main() {
  group('Quantity parsing', () {
    test('uses a documented scale of 1000', () {
      expect(Quantity.scale, 1000);
      expect(Quantity.decimalDigits, 3);
    });

    test('parses whole, fractional and signed values', () {
      expect(Quantity.tryParse('1')!.scaledValue, 1000);
      expect(Quantity.tryParse('1.5')!.scaledValue, 1500);
      expect(Quantity.tryParse('0.25')!.scaledValue, 250);
      expect(Quantity.tryParse('0.001')!.scaledValue, 1);
      expect(Quantity.tryParse('-2.75')!.scaledValue, -2750);
      expect(Quantity.tryParse('.5')!.scaledValue, 500);
    });

    test('rejects more than three fractional digits', () {
      expect(Quantity.tryParse('1.2345'), isNull);
    });

    test('rejects malformed input', () {
      expect(Quantity.tryParse(''), isNull);
      expect(Quantity.tryParse('abc'), isNull);
      expect(Quantity.tryParse('1.2.3'), isNull);
    });

    test('fromParts builds a fractional quantity', () {
      expect(Quantity.fromParts(1, 500).scaledValue, 1500);
      expect(Quantity.fromParts(2).scaledValue, 2000);
    });
  });

  group('Quantity arithmetic', () {
    test('addition and subtraction stay exact', () {
      final a = Quantity.tryParse('1.5')!;
      final b = Quantity.tryParse('0.25')!;
      expect((a + b).scaledValue, 1750);
      expect((a - b).scaledValue, 1250);
      expect((-a).scaledValue, -1500);
    });

    test('comparison operators work', () {
      final small = Quantity.tryParse('1.5')!;
      final big = Quantity.tryParse('2')!;
      expect(small < big, isTrue);
      expect(small <= big, isTrue);
      expect(big > small, isTrue);
      expect(big >= small, isTrue);
    });

    test('times multiplies by a whole number', () {
      expect(Quantity.tryParse('1.5')!.times(3).scaledValue, 4500);
    });
  });

  group('Quantity display', () {
    test('trims trailing zeros', () {
      expect(Quantity.tryParse('1.500')!.toDisplayString(), '1.5');
      expect(Quantity.tryParse('1.000')!.toDisplayString(), '1');
      expect(Quantity.tryParse('0.250')!.toDisplayString(), '0.25');
      expect(Quantity.tryParse('0.001')!.toDisplayString(), '0.001');
      expect(Quantity.zero.toDisplayString(), '0');
    });

    test('round trips through parse and display', () {
      for (final text in <String>['0', '1', '1.5', '0.25', '12.125', '-3.5']) {
        final quantity = Quantity.tryParse(text)!;
        expect(Quantity.tryParse(quantity.toDisplayString()), quantity);
      }
    });
  });

  group('extendLineTotal', () {
    test('multiplies a fractional quantity by an integer unit price', () {
      // 1.5 kg at 10.50 (1050 minor units) = 15.75 (1575 minor units).
      final quantity = Quantity.tryParse('1.5')!;
      expect(extendLineTotal(quantity, 1050), 1575);
    });

    test('rounds the result once', () {
      // 0.333 at 100 minor units = 33.3 -> 33.
      final quantity = Quantity.tryParse('0.333')!;
      expect(extendLineTotal(quantity, 100), 33);
    });

    test('a whole quantity is exactly the unit price times the count', () {
      final quantity = Quantity.tryParse('3')!;
      expect(extendLineTotal(quantity, 1999), 5997);
    });
  });
}
