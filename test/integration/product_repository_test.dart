import 'dart:io';

// Drift exports isNull/isNotNull query helpers that clash with the matcher
// functions of the same name; the query helpers are not needed here.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/errors/failures.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/core/utils/csv.dart';
import 'package:storeflow_pos/core/utils/pagination.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/features/products/domain/entities/product.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

void main() {
  late AppDatabase db;
  late ProductRepository products;

  setUp(() async {
    db = AppDatabase.memory();
    products = ProductRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('create', () {
    test('stores a product with its barcodes', () async {
      final id = await products.create(
        name: 'Arabic Coffee',
        sku: 'COF-1',
        purchaseCostMinor: 2500,
        sellingPriceMinor: 4000,
        minimumStockScaled: 2000,
        barcodes: const <String>['6281000000015', '6281000000022'],
      );

      final product = await products.findById(id);
      expect(product, isNotNull);
      expect(product!.name, 'Arabic Coffee');
      expect(product.sku, 'COF-1');
      expect(product.purchaseCostMinor, 2500);
      expect(product.sellingPriceMinor, 4000);
      expect(product.barcodes, hasLength(2));
      expect(product.hasStockRow, isFalse);
    });

    test('trims the name and rejects a blank one', () async {
      final id = await products.create(name: '  Trimmed  ');
      expect((await products.findById(id))!.name, 'Trimmed');

      await expectLater(
        products.create(name: '   '),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('rejects a duplicate SKU', () async {
      await products.create(name: 'First', sku: 'DUP');
      await expectLater(
        products.create(name: 'Second', sku: 'DUP'),
        throwsA(
          isA<ValidationFailure>().having((f) => f.field, 'field', 'sku'),
        ),
      );
    });

    test('rejects a barcode already assigned elsewhere', () async {
      await products.create(
        name: 'First',
        barcodes: const <String>['1111111111116'],
      );
      await expectLater(
        products.create(
          name: 'Second',
          barcodes: const <String>['1111111111116'],
        ),
        throwsA(
          isA<ValidationFailure>().having((f) => f.field, 'field', 'barcode'),
        ),
      );
    });

    test('rejects the same barcode twice on one product', () async {
      await expectLater(
        products.create(
          name: 'Dup',
          barcodes: const <String>['2222222222225', '2222222222225'],
        ),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('a rejected barcode leaves no product behind', () async {
      await products.create(
        name: 'First',
        barcodes: const <String>['3333333333332'],
      );
      await expectLater(
        products.create(name: 'Second', barcodes: const <String>['3333333333332']),
        throwsA(isA<ValidationFailure>()),
      );
      expect(await products.count(), 1);
    });

    test('rejects negative prices', () async {
      await expectLater(
        products.create(name: 'Bad', sellingPriceMinor: -1),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('stores an empty SKU as null rather than an empty string', () async {
      final id = await products.create(name: 'NoSku', sku: '   ');
      expect((await products.findById(id))!.sku, isNull);
    });

    test('allows several products with no SKU', () async {
      await products.create(name: 'A');
      await products.create(name: 'B');
      expect(await products.count(), 2);
    });
  });

  group('lookups', () {
    test('finds by barcode', () async {
      final id = await products.create(
        name: 'Scannable',
        barcodes: const <String>['4006381333931'],
      );
      final found = await products.findByBarcode('4006381333931');
      expect(found?.id, id);
    });

    test('returns null for an unknown barcode', () async {
      expect(await products.findByBarcode('0000000000000'), isNull);
    });

    test('finds by SKU', () async {
      final id = await products.create(name: 'Sku Product', sku: 'SKU-9');
      expect((await products.findBySku('SKU-9'))?.id, id);
      expect(await products.findBySku('MISSING'), isNull);
    });

    test('returns null for a missing id', () async {
      expect(await products.findById(424242), isNull);
    });
  });

  group('update', () {
    test('changes fields and replaces barcodes', () async {
      final id = await products.create(
        name: 'Before',
        sku: 'U-1',
        barcodes: const <String>['5000000000001'],
      );

      await products.update(
        id: id,
        name: 'After',
        sku: 'U-2',
        sellingPriceMinor: 999,
        barcodes: const <String>['5000000000002', '5000000000003'],
      );

      final product = await products.findById(id);
      expect(product!.name, 'After');
      expect(product.sku, 'U-2');
      expect(product.sellingPriceMinor, 999);
      expect(product.barcodes, hasLength(2));
      expect(await products.findByBarcode('5000000000001'), isNull);
      expect(await products.findByBarcode('5000000000002'), isNotNull);
    });

    test('leaves barcodes alone when none are given', () async {
      final id = await products.create(
        name: 'Keep',
        barcodes: const <String>['6000000000006'],
      );
      await products.update(id: id, name: 'Keep Renamed');
      expect((await products.findById(id))!.barcodes, hasLength(1));
    });

    test('rejects an unknown id', () async {
      await expectLater(
        products.update(id: 999, name: 'Ghost'),
        throwsA(isA<NotFoundFailure>()),
      );
    });

    test('rejects a SKU that belongs to another product', () async {
      await products.create(name: 'Other', sku: 'TAKEN');
      final id = await products.create(name: 'Mine', sku: 'MINE');
      await expectLater(
        products.update(id: id, name: 'Mine', sku: 'TAKEN'),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('allows a product to keep its own SKU', () async {
      final id = await products.create(name: 'Self', sku: 'SELF');
      await products.update(id: id, name: 'Self Renamed', sku: 'SELF');
      expect((await products.findById(id))!.sku, 'SELF');
    });
  });

  group('archive and restore', () {
    test('archive hides the product from the default listing', () async {
      final id = await products.create(name: 'Archivable');
      await products.archive(id);

      expect((await products.findById(id))!.isActive, isFalse);
      expect((await products.search()).totalCount, 0);
      expect(
        (await products.search(
          filter: const ProductFilter(includeArchived: true),
        ))
            .totalCount,
        1,
      );
    });

    test('restore brings it back', () async {
      final id = await products.create(name: 'Restorable');
      await products.archive(id);
      await products.restore(id);
      expect((await products.findById(id))!.isActive, isTrue);
      expect((await products.search()).totalCount, 1);
    });

    test('archiving an unknown id is rejected', () async {
      await expectLater(products.archive(12345), throwsA(isA<NotFoundFailure>()));
    });

    test('isReferenced is false for a brand new product', () async {
      final id = await products.create(name: 'Fresh');
      expect(await products.isReferenced(id), isFalse);
    });
  });

  group('search', () {
    setUp(() async {
      await products.create(
        name: 'Green Tea',
        sku: 'TEA-1',
        barcodes: const <String>['7000000000001'],
      );
      await products.create(
        name: 'Black Tea',
        sku: 'TEA-2',
        barcodes: const <String>['7000000000002'],
      );
      await products.create(name: 'Coffee Beans', sku: 'COF-1');
      await products.create(name: '100% Juice', sku: 'JUI-1');
    });

    test('matches on name', () async {
      final page = await products.search(
        filter: const ProductFilter(searchTerm: 'tea'),
      );
      expect(page.totalCount, 2);
    });

    test('matches on SKU', () async {
      final page = await products.search(
        filter: const ProductFilter(searchTerm: 'COF-1'),
      );
      expect(page.totalCount, 1);
      expect(page.items.single.name, 'Coffee Beans');
    });

    test('matches on barcode', () async {
      final page = await products.search(
        filter: const ProductFilter(searchTerm: '7000000000002'),
      );
      expect(page.totalCount, 1);
      expect(page.items.single.sku, 'TEA-2');
    });

    test('does not duplicate a product that matches twice', () async {
      final page = await products.search(
        filter: const ProductFilter(searchTerm: 'Tea'),
      );
      final ids = page.items.map((product) => product.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('treats a percent sign literally', () async {
      final page = await products.search(
        filter: const ProductFilter(searchTerm: '100%'),
      );
      expect(page.totalCount, 1);
      expect(page.items.single.name, '100% Juice');
    });

    test('returns nothing for an unmatched term', () async {
      final page = await products.search(
        filter: const ProductFilter(searchTerm: 'zzzz'),
      );
      expect(page.isEmpty, isTrue);
      expect(page.totalCount, 0);
    });

    test('pages without loading the whole catalog', () async {
      final firstPage = await products.search(
        request: const PageRequest(limit: 2),
      );
      expect(firstPage.items, hasLength(2));
      expect(firstPage.totalCount, 4);
      expect(firstPage.hasMore, isTrue);
      expect(firstPage.hasPrevious, isFalse);

      final secondPage = await products.search(
        request: const PageRequest(offset: 2, limit: 2),
      );
      expect(secondPage.items, hasLength(2));
      expect(secondPage.hasMore, isFalse);
      expect(secondPage.hasPrevious, isTrue);

      final firstIds = firstPage.items.map((product) => product.id).toSet();
      final secondIds = secondPage.items.map((product) => product.id).toSet();
      expect(firstIds.intersection(secondIds), isEmpty);
    });

    test('filters by category and resolves its name', () async {
      final categoryId = await db.into(db.categories).insert(
            CategoriesCompanion.insert(
              name: 'Drinks',
              createdAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      final coffee = await products.findBySku('COF-1');
      await products.update(
        id: coffee!.id,
        name: coffee.name,
        sku: coffee.sku,
        categoryId: categoryId,
      );

      final page = await products.search(
        filter: ProductFilter(categoryId: categoryId),
      );
      expect(page.totalCount, 1);
      expect(page.items.single.categoryName, 'Drinks');
    });

    test('reports every product as out of stock when none has stock', () async {
      final page = await products.search(
        filter: const ProductFilter(onlyOutOfStock: true),
      );
      expect(page.totalCount, 4);
    });

    test('reports no low stock when no threshold is set', () async {
      final page = await products.search(
        filter: const ProductFilter(lowStockOnly: true),
      );
      expect(page.totalCount, 0);
    });
  });

  group('low stock', () {
    test('includes a never-received product with a threshold', () async {
      await products.create(
        name: 'Threshold',
        minimumStockScaled: 5 * Quantity.scale,
      );
      final low = await products.lowStock();
      expect(low, hasLength(1));
      expect(low.single.name, 'Threshold');
    });

    test('excludes a product stocked above its threshold', () async {
      final id = await products.create(
        name: 'Stocked',
        minimumStockScaled: 2 * Quantity.scale,
      );
      await db.into(db.productStock).insert(
            ProductStockCompanion.insert(
              productId: Value(id),
              quantityScaled: Value(10 * Quantity.scale),
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      expect(await products.lowStock(), isEmpty);
    });

    test('includes a product at exactly its threshold', () async {
      final id = await products.create(
        name: 'AtThreshold',
        minimumStockScaled: 3 * Quantity.scale,
      );
      await db.into(db.productStock).insert(
            ProductStockCompanion.insert(
              productId: Value(id),
              quantityScaled: Value(3 * Quantity.scale),
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      expect(await products.lowStock(), hasLength(1));
    });
  });

  group('CSV export and import', () {
    test('round-trips through CSV', () async {
      await products.create(
        name: 'Export Me',
        sku: 'EXP-1',
        purchaseCostMinor: 1234,
        sellingPriceMinor: 5678,
        minimumStockScaled: 1500,
        description: 'Has, a comma',
        barcodes: const <String>['8000000000001', '8000000000002'],
      );

      final rows = await products.exportRows();
      final parsed = Csv.parse(Csv.encode(rows));

      expect(parsed.first.first, 'sku');
      final dataRow = parsed[1];
      expect(dataRow[0], 'EXP-1');
      expect(dataRow[1], 'Export Me');
      expect(dataRow[4], '12.34');
      expect(dataRow[5], '56.78');
      expect(dataRow[6], '1.5');
      expect(dataRow[8], '8000000000001|8000000000002');
      expect(dataRow[9], 'Has, a comma');
      expect(dataRow[10], '1');
    });

    test('imports new products and reports each row', () async {
      final rows = Csv.parse(
        'sku,name,purchase_cost,selling_price,minimum_stock,barcodes\n'
        'I-1,Imported One,10.00,15.00,2,9000000000001\n'
        'I-2,Imported Two,20.00,30.00,0,\n',
      );

      final report = await products.importRows(rows);
      expect(report.createdCount, 2);
      expect(report.updatedCount, 0);
      expect(report.hasRejections, isFalse);

      final imported = await products.findBySku('I-1');
      expect(imported!.name, 'Imported One');
      expect(imported.purchaseCostMinor, 1000);
      expect(imported.minimumStockScaled, 2000);
      expect(imported.barcodes, <String>['9000000000001']);
    });

    test('updates an existing product matched by SKU', () async {
      await products.create(name: 'Old Name', sku: 'UPD-1');
      final report = await products.importRows(
        Csv.parse('sku,name,selling_price\nUPD-1,New Name,99.99\n'),
      );

      expect(report.updatedCount, 1);
      expect(report.createdCount, 0);
      final updated = await products.findBySku('UPD-1');
      expect(updated!.name, 'New Name');
      expect(updated.sellingPriceMinor, 9999);
    });

    test('reports bad rows without abandoning the good ones', () async {
      final report = await products.importRows(
        Csv.parse(
          'sku,name,purchase_cost\n'
          'G-1,Good Row,5.00\n'
          'N-1,,1.00\n'
          'B-1,Bad Cost,not-a-number\n',
        ),
      );

      // The good row imports; the empty name and the unparseable cost are
      // reported individually so the user knows exactly which lines to fix.
      expect(report.createdCount, 1);
      expect(report.rejectedCount, 2);
      expect(report.totalRows, 3);
      expect(report.rejectedRows.map((row) => row.lineNumber), <int>[3, 4]);
      expect(report.rejectedRows.first.message, contains('Missing product name'));
      expect(report.rejectedRows.last.message, contains('purchase_cost'));
      expect(await products.findBySku('G-1'), isNotNull);
      expect(await products.findBySku('N-1'), isNull);
      expect(await products.findBySku('B-1'), isNull);
    });

    test('rejects a file with no name column', () async {
      await expectLater(
        products.importRows(Csv.parse('sku,price\nX-1,5.00\n')),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('rejects an empty file', () async {
      await expectLater(
        products.importRows(const <List<String>>[]),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('skips blank lines', () async {
      final report = await products.importRows(
        Csv.parse('name\nRow One\n\nRow Two\n'),
      );
      expect(report.createdCount, 2);
    });

    test('can refuse to update existing products', () async {
      await products.create(name: 'Existing', sku: 'KEEP-1');
      final report = await products.importRows(
        Csv.parse('sku,name\nKEEP-1,Renamed\n'),
        updateExisting: false,
      );
      expect(report.rejectedCount, 1);
      expect((await products.findBySku('KEEP-1'))!.name, 'Existing');
    });

    test('resolves a category and unit by name', () async {
      await db.into(db.categories).insert(
            CategoriesCompanion.insert(
              name: 'Snacks',
              createdAt: '2026-01-01T00:00:00.000Z',
              updatedAt: '2026-01-01T00:00:00.000Z',
            ),
          );
      await products.importRows(
        Csv.parse('name,category,unit\nChips,Snacks,kilogram\n'),
      );
      final imported = await products.search(
        filter: const ProductFilter(searchTerm: 'Chips'),
      );
      expect(imported.items.single.categoryName, 'Snacks');
      expect(imported.items.single.unitName, 'Kilogram');
    });
  });

  group('persistence', () {
    test('products and barcodes survive a reopen', () async {
      final dir = await Directory.systemTemp.createTemp('storeflow_products');
      final path = '${dir.path}/products.sqlite';

      final first = AppDatabase.open(overridePath: path);
      await ProductRepository(first).create(
        name: 'Persisted Product',
        sku: 'PER-1',
        barcodes: const <String>['1231231231231'],
      );
      await first.close();

      final second = AppDatabase.open(overridePath: path);
      final found = await ProductRepository(second)
          .findByBarcode('1231231231231');
      expect(found, isNotNull);
      expect(found!.name, 'Persisted Product');
      expect(found.sku, 'PER-1');
      await second.close();

      await dir.delete(recursive: true);
    });
  });
}
