import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/constants/enums.dart';
import 'package:storeflow_pos/core/errors/failures.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/core/utils/pagination.dart';
import 'package:storeflow_pos/features/inventory/data/inventory_service.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

void main() {
  late AppDatabase db;
  late InventoryService inventory;
  late ProductRepository products;
  late int productId;

  const scale = Quantity.scale;

  setUp(() async {
    db = AppDatabase.memory();
    inventory = InventoryService(db);
    products = ProductRepository(db);
    productId = await products.create(
      name: 'Test Widget',
      sku: 'W-1',
      purchaseCostMinor: 10000,
      sellingPriceMinor: 15000,
      minimumStockScaled: 5 * scale,
      barcodes: const <String>['1234567890128'],
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('ledger and cache stay consistent', () {
    test('a product starts with no stock row', () async {
      final position = await inventory.positionOf(productId);
      expect(position.hasRow, isFalse);
      expect(position.quantityScaled, 0);
      expect(position.averageCostMinor, 0);
    });

    test('an inbound movement creates the cache row', () async {
      final position = await inventory.apply(
        productId: productId,
        movementType: MovementType.openingStock,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.openingStock,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      expect(position.quantityScaled, 10 * scale);
      expect(position.averageCostMinor, 10000);

      final reread = await inventory.positionOf(productId);
      expect(reread.hasRow, isTrue);
      expect(reread.quantityScaled, 10 * scale);
    });

    test('every movement writes a ledger row with the resulting balance',
        () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.openingStock,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.openingStock,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      await inventory.apply(
        productId: productId,
        movementType: MovementType.sale,
        signedQuantityScaled: -3 * scale,
        referenceType: ReferenceType.sale,
        referenceId: 1,
        allowNegativeStock: false,
      );

      final page = await inventory.history(productId);
      expect(page.totalCount, 2);

      // Newest first.
      expect(page.items.first.quantityScaled, -3 * scale);
      expect(page.items.first.balanceAfterScaled, 7 * scale);
      expect(page.items.last.balanceAfterScaled, 10 * scale);
    });

    test('reconcile reports nothing after a valid sequence of movements',
        () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.openingStock,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.openingStock,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      await inventory.apply(
        productId: productId,
        movementType: MovementType.sale,
        signedQuantityScaled: -4 * scale,
        referenceType: ReferenceType.sale,
        allowNegativeStock: false,
      );
      await inventory.apply(
        productId: productId,
        movementType: MovementType.adjustmentIn,
        signedQuantityScaled: 2 * scale,
        referenceType: ReferenceType.stockAdjustment,
        allowNegativeStock: false,
        unitCost: 10000,
      );

      expect(await inventory.reconcile(), isEmpty);
    });

    test('reconcile detects a hand-edited cache row', () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.openingStock,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.openingStock,
        allowNegativeStock: false,
        unitCost: 10000,
      );

      // Corrupt the cache directly, bypassing the service, to prove the
      // reconciliation really compares the two sources.
      await (db.update(db.productStock)
            ..where((t) => t.productId.equals(productId)))
          .write(const ProductStockCompanion(quantityScaled: Value(999 * scale)));

      final discrepancies = await inventory.reconcile();
      expect(discrepancies, hasLength(1));
      expect(discrepancies.single.productId, productId);
      expect(discrepancies.single.cachedScaled, 999 * scale);
      expect(discrepancies.single.ledgerScaled, 10 * scale);
      expect(discrepancies.single.differenceScaled, 989 * scale);
      expect(discrepancies.single.isConsistent, isFalse);
    });
  });

  group('negative stock policy', () {
    test('is rejected by default', () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.openingStock,
        signedQuantityScaled: 5 * scale,
        referenceType: ReferenceType.openingStock,
        allowNegativeStock: false,
        unitCost: 10000,
      );

      await expectLater(
        inventory.apply(
          productId: productId,
          movementType: MovementType.sale,
          signedQuantityScaled: -6 * scale,
          referenceType: ReferenceType.sale,
          allowNegativeStock: false,
        ),
        throwsA(isA<InsufficientStockFailure>()),
      );

      // The rejected movement must leave no trace at all.
      expect((await inventory.positionOf(productId)).quantityScaled, 5 * scale);
      expect((await inventory.history(productId)).totalCount, 1);
    });

    test('is allowed when explicitly enabled', () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.sale,
        signedQuantityScaled: -2 * scale,
        referenceType: ReferenceType.sale,
        allowNegativeStock: true,
      );
      expect((await inventory.positionOf(productId)).quantityScaled, -2 * scale);
    });

    test('selling exactly the available quantity is allowed', () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.openingStock,
        signedQuantityScaled: 5 * scale,
        referenceType: ReferenceType.openingStock,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      final position = await inventory.apply(
        productId: productId,
        movementType: MovementType.sale,
        signedQuantityScaled: -5 * scale,
        referenceType: ReferenceType.sale,
        allowNegativeStock: false,
      );
      expect(position.quantityScaled, 0);
    });
  });

  group('sign and validation guards', () {
    test('a negative quantity on an inbound movement is rejected', () async {
      await expectLater(
        inventory.apply(
          productId: productId,
          movementType: MovementType.purchase,
          signedQuantityScaled: -5 * scale,
          referenceType: ReferenceType.purchase,
          allowNegativeStock: false,
          unitCost: 100,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('a positive quantity on an outbound movement is rejected', () async {
      await expectLater(
        inventory.apply(
          productId: productId,
          movementType: MovementType.sale,
          signedQuantityScaled: 5 * scale,
          referenceType: ReferenceType.sale,
          allowNegativeStock: true,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('a zero quantity is rejected', () async {
      await expectLater(
        inventory.apply(
          productId: productId,
          movementType: MovementType.sale,
          signedQuantityScaled: 0,
          referenceType: ReferenceType.sale,
          allowNegativeStock: true,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('an unknown product is rejected', () async {
      await expectLater(
        inventory.apply(
          productId: 999999,
          movementType: MovementType.openingStock,
          signedQuantityScaled: scale,
          referenceType: ReferenceType.openingStock,
          allowNegativeStock: false,
        ),
        throwsA(isA<NotFoundFailure>()),
      );
    });

    test('a manual movement cannot carry a reference id', () async {
      await expectLater(
        inventory.apply(
          productId: productId,
          movementType: MovementType.adjustmentIn,
          signedQuantityScaled: scale,
          referenceType: ReferenceType.manual,
          referenceId: 42,
          allowNegativeStock: false,
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });
  });

  group('weighted average through the service', () {
    test('two receipts produce the specification average', () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      final position = await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 12000,
      );
      expect(position.averageCostMinor, 11000);
    });

    test('a sale does not change the average cost', () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 11000,
      );
      final position = await inventory.apply(
        productId: productId,
        movementType: MovementType.sale,
        signedQuantityScaled: -2 * scale,
        referenceType: ReferenceType.sale,
        allowNegativeStock: false,
      );
      expect(position.averageCostMinor, 11000);
      expect(position.quantityScaled, 8 * scale);
    });

    test('a supplier return unwinds the average', () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 12000,
      );
      // Average is now 110. Send back the ten units that cost 120.
      final position = await inventory.apply(
        productId: productId,
        movementType: MovementType.supplierReturn,
        signedQuantityScaled: -10 * scale,
        referenceType: ReferenceType.purchaseReturn,
        allowNegativeStock: false,
        unitCost: 12000,
      );
      expect(position.quantityScaled, 10 * scale);
      expect(position.averageCostMinor, 10000);
    });

    test('an adjustment in with a cost re-weights the average', () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 4 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      final position = await inventory.apply(
        productId: productId,
        movementType: MovementType.adjustmentIn,
        signedQuantityScaled: 4 * scale,
        referenceType: ReferenceType.stockAdjustment,
        allowNegativeStock: false,
        unitCost: 20000,
      );
      expect(position.averageCostMinor, 15000);
    });
  });

  group('stock adjustment documents', () {
    test('posts multiple lines in one transaction', () async {
      final second = await products.create(name: 'Second', sku: 'W-2');

      await inventory.postAdjustment(
        reason: StockAdjustmentReason.opening,
        adjustmentNo: 'ADJ-000001',
        allowNegativeStock: false,
        lines: <StockAdjustmentLine>[
          StockAdjustmentLine(
            productId: productId,
            quantityScaled: 10 * scale,
            unitCost: 10000,
          ),
          StockAdjustmentLine(
            productId: second,
            quantityScaled: 5 * scale,
            unitCost: 20000,
          ),
        ],
      );

      expect((await inventory.positionOf(productId)).quantityScaled, 10 * scale);
      expect((await inventory.positionOf(second)).quantityScaled, 5 * scale);
      expect(await inventory.reconcile(), isEmpty);

      final documents = await db.select(db.stockAdjustments).get();
      expect(documents, hasLength(1));
      expect(documents.single.adjustmentNo, 'ADJ-000001');
      expect(documents.single.reason, StockAdjustmentReason.opening.wireValue);

      expect(await db.select(db.stockAdjustmentItems).get(), hasLength(2));
    });

    test('rolls the whole document back when one line fails', () async {
      final second = await products.create(name: 'Second', sku: 'W-2');

      await expectLater(
        inventory.postAdjustment(
          reason: StockAdjustmentReason.count,
          adjustmentNo: 'ADJ-000002',
          allowNegativeStock: false,
          lines: <StockAdjustmentLine>[
            StockAdjustmentLine(
              productId: productId,
              quantityScaled: 10 * scale,
              unitCost: 10000,
            ),
            // Nothing is on hand for `second`, so this line cannot be satisfied.
            StockAdjustmentLine(productId: second, quantityScaled: -3 * scale),
          ],
        ),
        throwsA(isA<InsufficientStockFailure>()),
      );

      // Neither the first line's movement nor the document may survive.
      expect((await inventory.positionOf(productId)).quantityScaled, 0);
      expect((await inventory.positionOf(second)).quantityScaled, 0);
      expect(await db.select(db.stockAdjustments).get(), isEmpty);
      expect(await db.select(db.stockAdjustmentItems).get(), isEmpty);
      expect(await db.select(db.inventoryMovements).get(), isEmpty);
      expect(await inventory.reconcile(), isEmpty);
    });

    test('rejects a document with no lines', () async {
      await expectLater(
        inventory.postAdjustment(
          reason: StockAdjustmentReason.count,
          adjustmentNo: 'ADJ-000003',
          allowNegativeStock: false,
          lines: const <StockAdjustmentLine>[],
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('rejects a zero-quantity line', () async {
      await expectLater(
        inventory.postAdjustment(
          reason: StockAdjustmentReason.count,
          adjustmentNo: 'ADJ-000004',
          allowNegativeStock: false,
          lines: <StockAdjustmentLine>[
            StockAdjustmentLine(productId: productId, quantityScaled: 0),
          ],
        ),
        throwsA(isA<ValidationFailure>()),
      );
      expect(await db.select(db.stockAdjustments).get(), isEmpty);
    });
  });

  group('valuation and aggregation', () {
    test('total stock value sums the active catalog', () async {
      final second = await products.create(name: 'Second', sku: 'W-2');

      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      await inventory.apply(
        productId: second,
        movementType: MovementType.purchase,
        signedQuantityScaled: 2 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 5000,
      );

      // 10 x 100.00 = 1000.00 and 2 x 50.00 = 100.00
      expect(await inventory.totalStockValueMinor(), 110000);
    });

    test('archived products are excluded from the total', () async {
      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      await products.archive(productId);
      expect(await inventory.totalStockValueMinor(), 0);
    });

    test('positionsOf omits products with no stock row', () async {
      final second = await products.create(name: 'Second', sku: 'W-2');
      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 3 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 100,
      );

      final positions = await inventory.positionsOf(<int>[productId, second]);
      expect(positions.keys, contains(productId));
      expect(positions.containsKey(second), isFalse);
      expect(positions[productId]!.quantityScaled, 3 * scale);
    });

    test('history is paged', () async {
      for (var i = 0; i < 7; i++) {
        await inventory.apply(
          productId: productId,
          movementType: MovementType.purchase,
          signedQuantityScaled: scale,
          referenceType: ReferenceType.purchase,
          allowNegativeStock: false,
          unitCost: 100 * (i + 1),
        );
      }
      final firstPage = await inventory.history(
        productId,
        request: const PageRequest(limit: 3),
      );
      expect(firstPage.items, hasLength(3));
      expect(firstPage.totalCount, 7);
      expect(firstPage.hasMore, isTrue);

      final lastPage = await inventory.history(
        productId,
        request: const PageRequest(offset: 6, limit: 3),
      );
      expect(lastPage.items, hasLength(1));
      expect(lastPage.hasMore, isFalse);
    });
  });

  group('persistence', () {
    test('stock survives closing and reopening the same file', () async {
      final dir = await Directory.systemTemp.createTemp('storeflow_stock');
      final path = '${dir.path}/stock.sqlite';

      final first = AppDatabase.open(overridePath: path);
      final firstProducts = ProductRepository(first);
      final firstInventory = InventoryService(first);
      final id = await firstProducts.create(name: 'Persisted', sku: 'P-1');
      await firstInventory.apply(
        productId: id,
        movementType: MovementType.purchase,
        signedQuantityScaled: 12 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 777,
      );
      await first.close();

      final second = AppDatabase.open(overridePath: path);
      final secondInventory = InventoryService(second);
      final position = await secondInventory.positionOf(id);
      expect(position.quantityScaled, 12 * scale);
      expect(position.averageCostMinor, 777);
      expect(await secondInventory.reconcile(), isEmpty);
      await second.close();

      await dir.delete(recursive: true);
    });
  });
}
