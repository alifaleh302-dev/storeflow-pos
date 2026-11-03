import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/constants/app_constants.dart';
import 'tables.dart';

part 'app_database.g.dart';

/// Extra indexes created after the generated schema.
///
/// Drift generates indexes for primary keys, unique columns and foreign keys
/// only when configured; these cover the columns the application actually
/// filters and sorts on, which is what keeps search and reporting responsive
/// on large catalogs.
const List<String> _customIndexes = <String>[
  'CREATE INDEX IF NOT EXISTS idx_products_name ON products (name)',
  'CREATE INDEX IF NOT EXISTS idx_products_category ON products (category_id)',
  'CREATE INDEX IF NOT EXISTS idx_products_active ON products (is_active)',
  'CREATE INDEX IF NOT EXISTS idx_barcodes_product ON product_barcodes (product_id)',
  'CREATE INDEX IF NOT EXISTS idx_sales_created ON sales (created_at)',
  'CREATE INDEX IF NOT EXISTS idx_sales_customer ON sales (customer_id)',
  'CREATE INDEX IF NOT EXISTS idx_sales_status ON sales (status)',
  'CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items (sale_id)',
  'CREATE INDEX IF NOT EXISTS idx_sale_items_product ON sale_items (product_id)',
  'CREATE INDEX IF NOT EXISTS idx_sale_payments_sale ON sale_payments (sale_id)',
  'CREATE INDEX IF NOT EXISTS idx_purchases_created ON purchases (created_at)',
  'CREATE INDEX IF NOT EXISTS idx_purchases_supplier ON purchases (supplier_id)',
  'CREATE INDEX IF NOT EXISTS idx_purchases_status ON purchases (status)',
  'CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items (purchase_id)',
  'CREATE INDEX IF NOT EXISTS idx_movements_product ON inventory_movements (product_id)',
  'CREATE INDEX IF NOT EXISTS idx_movements_created ON inventory_movements (created_at)',
  'CREATE INDEX IF NOT EXISTS idx_movements_reference ON inventory_movements (reference_type, reference_id)',
  'CREATE INDEX IF NOT EXISTS idx_customer_entries_customer ON customer_account_entries (customer_id)',
  'CREATE INDEX IF NOT EXISTS idx_customer_entries_created ON customer_account_entries (created_at)',
  'CREATE INDEX IF NOT EXISTS idx_supplier_entries_supplier ON supplier_account_entries (supplier_id)',
  'CREATE INDEX IF NOT EXISTS idx_supplier_entries_created ON supplier_account_entries (created_at)',
  'CREATE INDEX IF NOT EXISTS idx_expenses_created ON expenses (created_at)',
  'CREATE INDEX IF NOT EXISTS idx_cash_transactions_session ON cash_transactions (session_id)',
  'CREATE INDEX IF NOT EXISTS idx_cash_transactions_created ON cash_transactions (created_at)',
  'CREATE INDEX IF NOT EXISTS idx_exchange_rates_currency ON exchange_rates (currency_id, effective_from)',
  'CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs (created_at)',
  'CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_logs (entity_type, entity_id)',
];

@DriftDatabase(
  tables: <Type>[
    Currencies,
    ExchangeRates,
    Categories,
    Units,
    Products,
    ProductBarcodes,
    ProductPrices,
    ProductStock,
    Customers,
    Suppliers,
    CustomerAccountEntries,
    SupplierAccountEntries,
    Sales,
    SaleItems,
    SalePayments,
    SalesReturns,
    SalesReturnItems,
    Purchases,
    PurchaseItems,
    PurchasePayments,
    PurchaseReturns,
    PurchaseReturnItems,
    InventoryMovements,
    StockAdjustments,
    StockAdjustmentItems,
    CustomerPayments,
    SupplierPayments,
    ExpenseCategories,
    Expenses,
    CashSessions,
    CashTransactions,
    Users,
    Settings,
    AuditLogs,
    BackupHistory,
    DocumentSequences,
    IdempotencyKeys,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Opens the on-disk database in the application support directory.
  ///
  /// [overridePath] is used by tests and by the restore flow, which must open a
  /// candidate file before it replaces the live one.
  factory AppDatabase.open({String? overridePath}) {
    return AppDatabase(_openConnection(overridePath));
  }

  /// Opens an in-memory database. Used by unit and integration tests.
  factory AppDatabase.memory() => AppDatabase(NativeDatabase.memory());

  @override
  int get schemaVersion => kSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          await m.createAll();
          await _createCustomIndexes();
          await _seedDefaults();
        },
        onUpgrade: (Migrator m, int from, int to) async {
          await _migrate(m, from, to);
          await _createCustomIndexes();
        },
        beforeOpen: (details) async {
          // Foreign keys are off by default in SQLite. Every connection must
          // enable them, and this runs before any user query.
          await customStatement('PRAGMA foreign_keys = ON');
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA synchronous = NORMAL');
          if (details.wasCreated) {
            await _seedDefaults();
          }
        },
      );

  Future<void> _createCustomIndexes() async {
    for (final statement in _customIndexes) {
      await customStatement(statement);
    }
  }

  /// Schema migrations. Version 1 is the initial schema, so there is nothing to
  /// upgrade from yet. Future versions append cases here and must never delete
  /// posted financial rows.
  Future<void> _migrate(Migrator m, int from, int to) async {
    // Example for the next schema change:
    // if (from < 2) { await m.addColumn(products, products.someNewColumn); }
  }

  /// Inserts the rows the application cannot start without: the base currency,
  /// built-in units, the walk-in customer, expense categories and defaults.
  Future<void> _seedDefaults() async {
    await transaction(() async {
      final timestamp = DateTime.now().toUtc().toIso8601String();

      final existingCurrencies = await select(currencies).get();
      if (existingCurrencies.isEmpty) {
        await into(currencies).insert(
          CurrenciesCompanion.insert(
            code: 'SAR',
            name: 'Saudi Riyal',
            symbol: const Value('SAR'),
            decimalDigits: const Value(2),
            isBase: const Value(true),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
      }

      final existingUnits = await select(units).get();
      if (existingUnits.isEmpty) {
        const seeds = <(String, String, String, int)>[
          (UnitCodes.piece, 'Piece', 'pc', 0),
          (UnitCodes.box, 'Box', 'box', 0),
          (UnitCodes.kilogram, 'Kilogram', 'kg', 3),
          (UnitCodes.gram, 'Gram', 'g', 3),
          (UnitCodes.liter, 'Liter', 'L', 3),
          (UnitCodes.meter, 'Meter', 'm', 3),
          (UnitCodes.package, 'Package', 'pkg', 0),
        ];
        for (final (code, name, symbol, precision) in seeds) {
          await into(units).insert(
            UnitsCompanion.insert(
              name: name,
              symbol: symbol,
              code: code,
              quantityPrecision: Value(precision),
            ),
          );
        }
      }

      final existingCustomers = await select(customers).get();
      if (existingCustomers.isEmpty) {
        await into(customers).insert(
          CustomersCompanion.insert(
            name: 'Walk-in Customer',
            isWalkIn: const Value(true),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
      }

      final existingExpenseCategories = await select(expenseCategories).get();
      if (existingExpenseCategories.isEmpty) {
        const seeds = <(String, String)>[
          ('rent', 'Rent'),
          ('electricity', 'Electricity'),
          ('water', 'Water'),
          ('salaries', 'Salaries'),
          ('transportation', 'Transportation'),
          ('maintenance', 'Maintenance'),
          ('other', 'Other'),
        ];
        for (final (code, name) in seeds) {
          await into(expenseCategories).insert(
            ExpenseCategoriesCompanion.insert(name: name, code: code),
          );
        }
      }

      final existingUsers = await select(users).get();
      if (existingUsers.isEmpty) {
        await into(users).insert(
          UsersCompanion.insert(
            displayName: 'Owner',
            username: 'owner',
            isOwner: const Value(true),
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
        );
      }

      await _seedSetting(SettingsKeys.storeName, 'StoreFlow POS');
      await _seedSetting(SettingsKeys.locale, 'ar');
      await _seedSetting(SettingsKeys.themeMode, 'system');
      await _seedSetting(SettingsKeys.allowNegativeStock, 'false');
      await _seedSetting(SettingsKeys.receiptPaperWidth, '80');
      await _seedSetting(SettingsKeys.receiptCopies, '1');
      await _seedSetting(SettingsKeys.onboardingComplete, 'false');
      await _seedSetting(
        SettingsKeys.receiptFooter,
        'Thank you for your business',
      );
    });
  }

  Future<void> _seedSetting(String key, String value) async {
    final existing = await (select(settings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    if (existing != null) return;
    await into(settings).insert(
      SettingsCompanion.insert(
        key: key,
        value: value,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  /// Runs `PRAGMA integrity_check` and returns the reported problems.
  Future<List<String>> checkIntegrity() async {
    final rows = await customSelect('PRAGMA integrity_check').get();
    return rows
        .map((row) => row.read<String>('integrity_check'))
        .where((value) => value != 'ok')
        .toList();
  }

  /// Runs `PRAGMA foreign_key_check` and returns the reported violations.
  Future<List<String>> checkForeignKeys() async {
    final rows = await customSelect('PRAGMA foreign_key_check').get();
    return rows.map((row) => row.toString()).toList();
  }
}

QueryExecutor _openConnection(String? overridePath) {
  return LazyDatabase(() async {
    final String filePath;
    if (overridePath != null) {
      filePath = overridePath;
    } else {
      final directory = await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      filePath = p.join(directory.path, 'storeflow.sqlite');
    }
    // Ensure the parent directory exists for override paths too.
    final parent = Directory(p.dirname(filePath));
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    final file = File(filePath);
    return NativeDatabase.createInBackground(
      file,
      setup: (raw) {
        raw.execute('PRAGMA foreign_keys = ON');
      },
    );
  });
}

/// Reads the SQLite library version actually linked at runtime, for diagnostics.
String sqliteRuntimeVersion() => sqlite3.version.libVersion;
