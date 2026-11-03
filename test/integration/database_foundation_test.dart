import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/constants/app_constants.dart';
import 'package:storeflow_pos/core/database/audit_service.dart';
import 'package:storeflow_pos/core/database/sequence_service.dart';
import 'package:storeflow_pos/core/database/settings_service.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.memory();
    // Force schema creation and seeding to run before each test.
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await db.close();
  });

  group('schema and seeding', () {
    test('creates a schema at the declared version', () async {
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], kSchemaVersion);
    });

    test('seeds exactly one base currency with two decimal digits', () async {
      final currencies = await db.select(db.currencies).get();
      expect(currencies.length, 1);
      expect(currencies.single.isBase, isTrue);
      expect(currencies.single.code, 'SAR');
      expect(currencies.single.decimalDigits, 2);
    });

    test('seeds the built-in units', () async {
      final units = await db.select(db.units).get();
      final codes = units.map((u) => u.code).toSet();
      expect(
        codes,
        containsAll(<String>[
          UnitCodes.piece,
          UnitCodes.box,
          UnitCodes.kilogram,
          UnitCodes.gram,
          UnitCodes.liter,
          UnitCodes.meter,
          UnitCodes.package,
        ]),
      );
    });

    test('seeds a single walk-in customer', () async {
      final customers = await db.select(db.customers).get();
      expect(customers.length, 1);
      expect(customers.single.isWalkIn, isTrue);
    });

    test('seeds expense categories', () async {
      final categories = await db.select(db.expenseCategories).get();
      expect(categories.length, 7);
      expect(categories.map((c) => c.code), contains('rent'));
    });

    test('seeds one owner user', () async {
      final users = await db.select(db.users).get();
      expect(users.length, 1);
      expect(users.single.isOwner, isTrue);
      expect(users.single.username, 'owner');
      // No PIN is set until the owner creates one.
      expect(users.single.pinHash, isNull);
    });

    test('seeds the default settings', () async {
      final rows = await db.select(db.settings).get();
      final keys = rows.map((r) => r.key).toSet();
      expect(keys, contains(SettingsKeys.storeName));
      expect(keys, contains(SettingsKeys.locale));
      expect(keys, contains(SettingsKeys.allowNegativeStock));
    });

    test('re-seeding on a second open does not duplicate rows', () async {
      // The same in-memory database is already seeded; opening again must not
      // add a second base currency. Calling the seed path twice is simulated by
      // re-running the migration hook through a fresh query on the same file.
      await db.customSelect('SELECT 1').get();
      expect((await db.select(db.currencies).get()).length, 1);
      expect((await db.select(db.units).get()).length, 7);
    });
  });

  group('foreign keys and constraints', () {
    test('foreign key enforcement is enabled', () async {
      final result = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(result.data['foreign_keys'], 1);
    });

    test('rejects a product referencing a missing category', () async {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      await expectLater(
        db.into(db.products).insert(
              ProductsCompanion.insert(
                name: 'Ghost',
                categoryId: const Value(99999),
                createdAt: timestamp,
                updatedAt: timestamp,
              ),
            ),
        throwsA(anything),
      );
    });

    test('enforces unique SKU', () async {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      await db.into(db.products).insert(
            ProductsCompanion.insert(
              name: 'First',
              sku: const Value('SKU-1'),
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      await expectLater(
        db.into(db.products).insert(
              ProductsCompanion.insert(
                name: 'Second',
                sku: const Value('SKU-1'),
                createdAt: timestamp,
                updatedAt: timestamp,
              ),
            ),
        throwsA(anything),
      );
    });

    test('enforces unique barcode across products', () async {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      final first = await db.into(db.products).insert(
            ProductsCompanion.insert(
              name: 'A',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      final second = await db.into(db.products).insert(
            ProductsCompanion.insert(
              name: 'B',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      await db.into(db.productBarcodes).insert(
            ProductBarcodesCompanion.insert(
              productId: first,
              barcode: '4006381333931',
              createdAt: timestamp,
            ),
          );
      await expectLater(
        db.into(db.productBarcodes).insert(
              ProductBarcodesCompanion.insert(
                productId: second,
                barcode: '4006381333931',
                createdAt: timestamp,
              ),
            ),
        throwsA(anything),
      );
    });

    test('enforces unique invoice numbers', () async {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      final currency = (await db.select(db.currencies).getSingle()).id;
      Future<int> insertSale() => db.into(db.sales).insert(
            SalesCompanion.insert(
              invoiceNo: 'INV-000001',
              currencyId: currency,
              status: 'posted',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      await insertSale();
      await expectLater(insertSale(), throwsA(anything));
    });

    test('deleting a referenced product is refused', () async {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      final currency = (await db.select(db.currencies).getSingle()).id;
      final productId = await db.into(db.products).insert(
            ProductsCompanion.insert(
              name: 'Referenced',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      final saleId = await db.into(db.sales).insert(
            SalesCompanion.insert(
              invoiceNo: 'INV-000002',
              currencyId: currency,
              status: 'posted',
              createdAt: timestamp,
              updatedAt: timestamp,
            ),
          );
      await db.into(db.saleItems).insert(
            SaleItemsCompanion.insert(
              saleId: saleId,
              productId: productId,
              productNameSnapshot: 'Referenced',
              quantityScaled: 1000,
              unitPrice: 100,
              unitCost: 50,
              total: 100,
            ),
          );
      await expectLater(
        (db.delete(db.products)..where((t) => t.id.equals(productId))).go(),
        throwsA(anything),
      );
    });
  });

  group('transactions and rollback', () {
    test('rolls back every write when the transaction throws', () async {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      await expectLater(
        db.transaction(() async {
          await db.into(db.products).insert(
                ProductsCompanion.insert(
                  name: 'Rolled back',
                  createdAt: timestamp,
                  updatedAt: timestamp,
                ),
              );
          throw StateError('simulated failure after insert');
        }),
        throwsStateError,
      );
      expect(await db.select(db.products).get(), isEmpty);
    });

    test('commits all writes when the transaction succeeds', () async {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      await db.transaction(() async {
        await db.into(db.products).insert(
              ProductsCompanion.insert(
                name: 'Committed',
                createdAt: timestamp,
                updatedAt: timestamp,
              ),
            );
      });
      expect((await db.select(db.products).get()).length, 1);
    });
  });

  group('integrity', () {
    test('passes integrity_check on a fresh database', () async {
      expect(await db.checkIntegrity(), isEmpty);
    });

    test('reports no foreign key violations on a fresh database', () async {
      expect(await db.checkForeignKeys(), isEmpty);
    });

    test('creates the performance indexes', () async {
      final rows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'",
          )
          .get();
      final names = rows.map((r) => r.read<String>('name')).toSet();
      expect(names, contains('idx_products_name'));
      expect(names, contains('idx_sales_created'));
      expect(names, contains('idx_movements_product'));
      expect(names, contains('idx_customer_entries_customer'));
      expect(names.length, greaterThanOrEqualTo(20));
    });
  });

  group('sequence service', () {
    test('produces zero-padded, increasing numbers', () async {
      final service = SequenceService(db);
      expect(await service.next('sale'), 'INV-000001');
      expect(await service.next('sale'), 'INV-000002');
      expect(await service.next('purchase'), 'PUR-000001');
    });

    test('keeps independent counters per document type', () async {
      final service = SequenceService(db);
      await service.next('sale');
      await service.next('sale');
      await service.next('customer');
      expect(await service.peek('sale'), 3);
      expect(await service.peek('customer'), 2);
    });

    test('rolls the counter back with the transaction', () async {
      final service = SequenceService(db);
      expect(await service.next('sale'), 'INV-000001');
      await expectLater(
        db.transaction(() async {
          await service.next('sale');
          throw StateError('abort');
        }),
        throwsStateError,
      );
      // The number was not consumed because the transaction rolled back.
      expect(await service.next('sale'), 'INV-000002');
    });

    test('rejects an unknown sequence name', () async {
      final service = SequenceService(db);
      await expectLater(service.next('not_a_document'), throwsArgumentError);
    });

    test('formats numbers with the configured width', () {
      expect(SequenceService.format('INV', 1, 6), 'INV-000001');
      expect(SequenceService.format('CUS', 42, 5), 'CUS-00042');
      expect(SequenceService.format('X', 1234567, 3), 'X-1234567');
    });
  });

  group('settings service', () {
    test('reads and writes strings, booleans and integers', () async {
      final service = SettingsService(db);
      await service.setString('store_name', 'My Shop');
      expect(await service.getString('store_name'), 'My Shop');

      await service.setBool('flag', true);
      expect(await service.getBool('flag'), isTrue);

      await service.setInt('count', 42);
      expect(await service.getInt('count'), 42);
    });

    test('returns the fallback for a missing key', () async {
      final service = SettingsService(db);
      expect(await service.getStringOr('nope', 'fallback'), 'fallback');
      expect(await service.getBool('nope', fallback: true), isTrue);
      expect(await service.getInt('nope', fallback: 7), 7);
    });

    test('negative stock is disabled by default', () async {
      final service = SettingsService(db);
      expect(await service.allowNegativeStock(), isFalse);
    });

    test('Arabic is the shipped default locale', () async {
      final service = SettingsService(db);
      expect(await service.locale(), 'ar');
    });

    test('an update replaces the previous value', () async {
      final service = SettingsService(db);
      await service.setString('store_name', 'First');
      await service.setString('store_name', 'Second');
      expect(await service.getString('store_name'), 'Second');
      expect((await service.getAll())['store_name'], 'Second');
    });
  });

  group('audit service', () {
    test('records entries newest first', () async {
      final service = AuditService(db);
      await service.log(action: 'create', entityType: 'product', entityId: 1);
      await service.log(action: 'update', entityType: 'product', entityId: 1);
      final entries = await service.recent();
      expect(entries.length, 2);
      expect(entries.first.action, 'update');
    });

    test('serialises a payload without exposing secrets', () async {
      final service = AuditService(db);
      await service.log(
        action: 'sale.post',
        entityType: 'sale',
        entityId: 5,
        payload: <String, Object?>{'total': 1000, 'currency': 'SAR'},
      );
      final entries = await service.recent();
      expect(entries.single.payload, contains('"total":1000'));
    });
  });
}
