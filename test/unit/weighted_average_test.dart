import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/core/money/weighted_average.dart';

void main() {
  group('WeightedAverage.applyInbound', () {
    test('matches the specification worked example', () {
      // 10 units at 100, then 10 units at 120 -> average 110.
      final afterFirst = WeightedAverage.applyInbound(
        oldQuantityScaled: 0,
        oldAverageCost: 0,
        inboundScaled: 10 * Quantity.scale,
        unitCost: 10000,
      );
      expect(afterFirst, 10000);

      final afterSecond = WeightedAverage.applyInbound(
        oldQuantityScaled: 10 * Quantity.scale,
        oldAverageCost: afterFirst,
        inboundScaled: 10 * Quantity.scale,
        unitCost: 12000,
      );
      expect(afterSecond, 11000);
    });

    test('takes the incoming cost when there is no stock on hand', () {
      expect(
        WeightedAverage.applyInbound(
          oldQuantityScaled: 0,
          oldAverageCost: 0,
          inboundScaled: 5000,
          unitCost: 777,
        ),
        777,
      );
    });

    test('takes the incoming cost when stock is negative', () {
      // A shop that enabled negative stock and has since restocked: the incoming
      // cost is the only defensible average.
      expect(
        WeightedAverage.applyInbound(
          oldQuantityScaled: -3 * Quantity.scale,
          oldAverageCost: 9999,
          inboundScaled: 5 * Quantity.scale,
          unitCost: 250,
        ),
        250,
      );
    });

    test('weights by quantity, not by the number of receipts', () {
      // 1 unit at 100 then 9 units at 200 -> (100 + 1800) / 10 = 190.
      expect(
        WeightedAverage.applyInbound(
          oldQuantityScaled: 1 * Quantity.scale,
          oldAverageCost: 10000,
          inboundScaled: 9 * Quantity.scale,
          unitCost: 20000,
        ),
        19000,
      );
    });

    test('rounds once, half away from zero', () {
      // (1*1 + 1*2) / 2 = 1.5 -> 2.
      expect(
        WeightedAverage.applyInbound(
          oldQuantityScaled: 1000,
          oldAverageCost: 1,
          inboundScaled: 1000,
          unitCost: 2,
        ),
        2,
      );
    });

    test('supports fractional inbound quantities', () {
      // 0.5 kg at 100 plus 0.5 kg at 200 -> 150.
      expect(
        WeightedAverage.applyInbound(
          oldQuantityScaled: 500,
          oldAverageCost: 10000,
          inboundScaled: 500,
          unitCost: 20000,
        ),
        15000,
      );
    });

    test('rejects a non-positive inbound quantity', () {
      expect(
        () => WeightedAverage.applyInbound(
          oldQuantityScaled: 1000,
          oldAverageCost: 100,
          inboundScaled: 0,
          unitCost: 100,
        ),
        throwsArgumentError,
      );
    });

    test('rejects a negative cost', () {
      expect(
        () => WeightedAverage.applyInbound(
          oldQuantityScaled: 0,
          oldAverageCost: 0,
          inboundScaled: 1000,
          unitCost: -1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('WeightedAverage.applyOutbound', () {
    test('leaves the average unchanged', () {
      expect(
        WeightedAverage.applyOutbound(
          oldQuantityScaled: 10 * Quantity.scale,
          oldAverageCost: 11000,
          outboundScaled: 3 * Quantity.scale,
        ),
        11000,
      );
    });

    test('rejects a non-positive outbound quantity', () {
      expect(
        () => WeightedAverage.applyOutbound(
          oldQuantityScaled: 1000,
          oldAverageCost: 100,
          outboundScaled: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('WeightedAverage.costOfGoods', () {
    test('computes an exact whole-unit cost', () {
      expect(
        WeightedAverage.costOfGoods(
          quantityScaled: 3 * Quantity.scale,
          averageCost: 11000,
        ),
        33000,
      );
    });

    test('computes a fractional quantity cost with one rounding', () {
      // 1.5 units at 110.00 -> 165.00
      expect(
        WeightedAverage.costOfGoods(quantityScaled: 1500, averageCost: 11000),
        16500,
      );
    });

    test('rounds a repeating fraction half away from zero', () {
      // 1 unit at 1 minor unit costs 1; a third of a unit costs 0.333 -> 0.
      expect(
        WeightedAverage.costOfGoods(quantityScaled: 333, averageCost: 1),
        0,
      );
      // Two thirds of a unit at 1 minor unit -> 0.667 -> 1.
      expect(
        WeightedAverage.costOfGoods(quantityScaled: 667, averageCost: 1),
        1,
      );
    });
  });

  group('WeightedAverage.stockValue', () {
    test('is zero for a non-positive quantity', () {
      expect(
        WeightedAverage.stockValue(quantityScaled: 0, averageCost: 100),
        0,
      );
      expect(
        WeightedAverage.stockValue(quantityScaled: -500, averageCost: 100),
        0,
      );
    });

    test('values a fractional quantity', () {
      expect(
        WeightedAverage.stockValue(quantityScaled: 2500, averageCost: 4000),
        10000,
      );
    });
  });

  group('WeightedAverage.reverseInbound', () {
    test('restores the pre-receipt average', () {
      // Start 10 units at 100, receive 10 at 120 -> average 110.
      // Returning all 10 received units must restore 100.
      expect(
        WeightedAverage.reverseInbound(
          quantityScaled: 20 * Quantity.scale,
          averageCost: 11000,
          inboundScaled: 10 * Quantity.scale,
          unitCost: 12000,
        ),
        10000,
      );
    });

    test('falls back to the incoming cost when nothing would remain', () {
      expect(
        WeightedAverage.reverseInbound(
          quantityScaled: 10 * Quantity.scale,
          averageCost: 11000,
          inboundScaled: 10 * Quantity.scale,
          unitCost: 12000,
        ),
        12000,
      );
    });

    test('clamps to zero rather than producing a negative value', () {
      // The receipt contributed more than the whole current value, which can
      // happen if cheaper receipts have since dragged the average down.
      expect(
        WeightedAverage.reverseInbound(
          quantityScaled: 10 * Quantity.scale,
          averageCost: 1000,
          inboundScaled: 9 * Quantity.scale,
          unitCost: 2000,
        ),
        0,
      );
    });
  });

  group('WeightedAverage consistency', () {
    test('a receipt followed by a full reversal is a round trip', () {
      const scale = Quantity.scale;
      var quantity = 7 * scale;
      var average = 1234;

      final before = average;
      average = WeightedAverage.applyInbound(
        oldQuantityScaled: quantity,
        oldAverageCost: average,
        inboundScaled: 5 * scale,
        unitCost: 4321,
      );
      quantity += 5 * scale;

      final restored = WeightedAverage.reverseInbound(
        quantityScaled: quantity,
        averageCost: average,
        inboundScaled: 5 * scale,
        unitCost: 4321,
      );
      expect(restored, before);
    });

    test('value is conserved across a receipt', () {
      const scale = Quantity.scale;
      // Value is quantity x cost / scale, so these are 1000 and 1200 minor units.
      final oldValue = WeightedAverage.stockValue(
        quantityScaled: 10 * scale,
        averageCost: 100,
      );
      final inboundValue = WeightedAverage.stockValue(
        quantityScaled: 10 * scale,
        averageCost: 120,
      );
      final newAverage = WeightedAverage.applyInbound(
        oldQuantityScaled: 10 * scale,
        oldAverageCost: 100,
        inboundScaled: 10 * scale,
        unitCost: 120,
      );
      final newValue = WeightedAverage.stockValue(
        quantityScaled: 20 * scale,
        averageCost: newAverage,
      );
      expect(newValue, oldValue + inboundValue);
    });
  });
}
