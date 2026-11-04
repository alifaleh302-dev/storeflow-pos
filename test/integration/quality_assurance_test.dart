import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:storeflow_pos/core/constants/app_constants.dart';
import 'package:storeflow_pos/core/constants/enums.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/features/inventory/data/inventory_service.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/features/sales/data/repositories/sale_repository.dart';
import 'package:storeflow_pos/features/sales/domain/entities/sale.dart';
import 'package:storeflow_pos/features/sales/domain/services/sale_calculator.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

/// Final quality checks that need a real file on disk.
///
/// The rest of the suite runs against an in-memory database, which cannot show
/// whether data actually survives a restart, whether the file is a valid SQLite
/// database, or whether foreign keys are enforced on a connection opened normally.
/// These tests use a real file for exactly those reasons.
void main() {
  const scale = Quantity.scale;

  late Directory workspace;
  late String databasePath;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('sfp_qa_');
    databasePath = p.join(workspace.path, 'storeflow.sqlite');
  });

  tearDown(() async {
    if (workspace.existsSync()) {
      await workspace.delete(recursive: true);
    }
  });

  group('persistence', () {
    test('data written in one session is readable in the next', () async {
      final first = AppDatabase.open(overridePath: databasePath);
      final productId = await ProductRepository(first).create(
        name: 'Persistent Widget',
        purchaseCostMinor: 10000,
        sellingPriceMinor: 15000,
      );
      await first.close();

      // A completely new database object, as after a restart.
      final second = AppDatabase.open(overridePath: databasePath);
      final product = await ProductRepository(second).findById(productId);
      expect(product, isNotNull);
      expect(product!.name, 'Persistent Widget');
      await second.close();
    });

    test('a posted sale and its ledger survive a restart', () async {
      final first = AppDatabase.open(overridePath: databasePath);
      final products = ProductRepository(first);
      final inventory = InventoryService(first);
      final sales = SaleRepository(first);
      final currencyId = (await (first.select(first.currencies)
                ..where((t) => t.isBase.equals(true)))
              .getSingle())
          .id;

      final productId = await products.create(
        name: 'Widget',
        purchaseCostMinor: 10000,
        sellingPriceMinor: 15000,
      );
      await inventory.apply(
        productId: productId,
        movementType: MovementType.openingStock,
        signedQuantityScaled: 5 * scale,
        referenceType: ReferenceType.manual,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      await sales.post(
        draft: SaleDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: productId,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ],
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: currencyId,
            amountMinor: 30000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 30000,
          ),
        ],
      );
      await first.close();

      final second = AppDatabase.open(overridePath: databasePath);
      final stock = await second.select(second.productStock).getSingle();
      // Five in, two sold.
      expect(stock.quantityScaled, 3 * scale);
      final movements = await second.select(second.inventoryMovements).get();
      expect(movements, hasLength(2));
      await second.close();
    });
  });

  group('database integrity', () {
    test('a fresh database passes its own integrity check', () async {
      final db = AppDatabase.open(overridePath: databasePath);
      await db.select(db.currencies).get();
      expect(await db.checkIntegrity(), isEmpty);
      expect(await db.checkForeignKeys(), isEmpty);
      await db.close();
    });

    test('a database full of records still passes its integrity check', () async {
      final db = AppDatabase.open(overridePath: databasePath);
      final products = ProductRepository(db);
      for (var i = 0; i < 25; i++) {
        await products.create(
          name: 'Product $i',
          sku: 'SKU-$i',
          purchaseCostMinor: 1000 + i,
          sellingPriceMinor: 2000 + i,
        );
      }
      expect(await db.checkIntegrity(), isEmpty);
      expect(await db.checkForeignKeys(), isEmpty);
      await db.close();
    });

    test('foreign keys are enforced on a normally opened connection', () async {
      final db = AppDatabase.open(overridePath: databasePath);
      await db.select(db.currencies).get();

      // A sale item pointing at a product that does not exist must be refused.
      await expectLater(
        db.into(db.saleItems).insert(
              SaleItemsCompanion.insert(
                saleId: 9999,
                productId: 9999,
                productNameSnapshot: 'Ghost',
                quantityScaled: scale,
                unitPrice: 100,
                unitCost: 100,
                total: 100,
              ),
            ),
        throwsA(isA<Exception>()),
      );
      await db.close();
    });

    test('the schema version matches the constant the code declares', () async {
      final db = AppDatabase.open(overridePath: databasePath);
      await db.select(db.currencies).get();
      expect(db.schemaVersion, kSchemaVersion);
      await db.close();
    });

    test('a reopen after a crash leaves a usable database', () async {
      // Write, then abandon the database without closing it cleanly, which is
      // what an abrupt exit looks like. The write-ahead log should recover.
      final first = AppDatabase.open(overridePath: databasePath);
      await ProductRepository(first).create(
        name: 'Survivor',
        purchaseCostMinor: 1000,
        sellingPriceMinor: 2000,
      );
      // Deliberately not closed.

      final second = AppDatabase.open(overridePath: databasePath);
      expect(await second.checkIntegrity(), isEmpty);
      final products = await second.select(second.products).get();
      expect(products, hasLength(1));
      expect(products.single.name, 'Survivor');
      await second.close();
      await first.close();
    });
  });

  group('transaction rollback', () {
    test('a failed sale leaves no invoice, no movement and no stock change', () async {
      final db = AppDatabase.open(overridePath: databasePath);
      final products = ProductRepository(db);
      final inventory = InventoryService(db);
      final sales = SaleRepository(db);
      final currencyId = (await (db.select(db.currencies)
                ..where((t) => t.isBase.equals(true)))
              .getSingle())
          .id;

      final productId = await products.create(
        name: 'Widget',
        purchaseCostMinor: 10000,
        sellingPriceMinor: 15000,
      );
      await inventory.apply(
        productId: productId,
        movementType: MovementType.openingStock,
        signedQuantityScaled: 5 * scale,
        referenceType: ReferenceType.manual,
        allowNegativeStock: false,
        unitCost: 10000,
      );

      // Ask for more than is in stock. The sale must be refused as a whole.
      await expectLater(
        sales.post(
          draft: SaleDraft(
            currencyId: currencyId,
            currencyDecimalDigits: 2,
            lines: <SaleLine>[
              SaleLine(
                productId: productId,
                productName: 'Widget',
                quantityScaled: 50 * scale,
                unitPriceMinor: 15000,
                unitCostMinor: 10000,
              ),
            ],
          ),
          payments: <PaymentAllocation>[
            PaymentAllocation(
              paymentMethod: PaymentMethod.cash,
              currencyId: currencyId,
              amountMinor: 750000,
              exchangeRateNumerator: 1,
              exchangeRateDenominator: 1,
              baseAmountMinor: 750000,
            ),
          ],
        ),
        throwsA(isA<Exception>()),
      );

      // Nothing was written: no invoice, no ledger entry, and the stock is intact.
      expect(await db.select(db.sales).get(), isEmpty);
      expect(await db.select(db.saleItems).get(), isEmpty);
      expect(await db.select(db.salePayments).get(), isEmpty);
      final movements = await db.select(db.inventoryMovements).get();
      expect(movements, hasLength(1)); // only the opening stock
      final stock = await db.select(db.productStock).getSingle();
      expect(stock.quantityScaled, 5 * scale);

      await db.close();
    });

    test('a negative-stock sale is refused when the policy forbids it', () async {
      final db = AppDatabase.open(overridePath: databasePath);
      final products = ProductRepository(db);
      final inventory = InventoryService(db);

      final productId = await products.create(
        name: 'Widget',
        purchaseCostMinor: 1000,
        sellingPriceMinor: 2000,
      );

      await expectLater(
        inventory.apply(
          productId: productId,
          movementType: MovementType.sale,
          signedQuantityScaled: -1 * scale,
          referenceType: ReferenceType.sale,
          allowNegativeStock: false,
        ),
        throwsA(isA<Exception>()),
      );

      // The rejected movement created no stock row at all, which is the same as
      // holding nothing: the ledger and the balance agree.
      final stock = await db.select(db.productStock).getSingleOrNull();
      expect(stock?.quantityScaled ?? 0, 0);
      expect(await db.select(db.inventoryMovements).get(), isEmpty);
      await db.close();
    });
  });
}
