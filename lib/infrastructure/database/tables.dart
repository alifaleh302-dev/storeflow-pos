import 'package:drift/drift.dart';

// Money columns store integer minor units; quantity columns store integers
// scaled by Quantity.scale (1000); timestamps store UTC ISO-8601 text.
//
// Deletion policy: posted financial documents are never deleted. References
// from documents to master data (products, customers, suppliers, currencies)
// use KeyAction.restrict so the database itself refuses to orphan history.
// Purely structural children (invoice lines, barcode rows) use cascade.

@DataClassName('CurrencyRow')
class Currencies extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get code => text().withLength(min: 2, max: 8).unique()();
  TextColumn get name => text()();
  TextColumn get symbol => text().nullable()();
  IntColumn get decimalDigits => integer().withDefault(const Constant(2))();
  BoolColumn get isBase => boolean().withDefault(const Constant(false))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@DataClassName('ExchangeRateRow')
class ExchangeRates extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  // base_minor = round(tx_minor * numerator / denominator); see ExchangeRate.
  IntColumn get numerator => integer()();
  IntColumn get denominator => integer()();
  TextColumn get effectiveFrom => text()();
  TextColumn get createdAt => text()();
}

@DataClassName('CategoryRow')
class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  IntColumn get parentId =>
      integer().nullable().references(Categories, #id, onDelete: KeyAction.restrict)();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@DataClassName('UnitRow')
class Units extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get symbol => text()();
  TextColumn get code => text().unique()();
  IntColumn get quantityPrecision => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

@DataClassName('ProductRow')
class Products extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get sku => text().nullable().unique()();
  IntColumn get categoryId =>
      integer().nullable().references(Categories, #id, onDelete: KeyAction.restrict)();
  IntColumn get unitId =>
      integer().nullable().references(Units, #id, onDelete: KeyAction.restrict)();
  IntColumn get purchaseCost => integer().withDefault(const Constant(0))();
  IntColumn get sellingPrice => integer().withDefault(const Constant(0))();
  IntColumn get minimumStock => integer().withDefault(const Constant(0))();
  TextColumn get description => text().nullable()();
  TextColumn get imagePath => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@DataClassName('ProductBarcodeRow')
class ProductBarcodes extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId =>
      integer().references(Products, #id, onDelete: KeyAction.cascade)();
  TextColumn get barcode => text().unique()();
  TextColumn get createdAt => text()();
}

@DataClassName('ProductPriceRow')
class ProductPrices extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId =>
      integer().references(Products, #id, onDelete: KeyAction.cascade)();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get priceMinor => integer()();
  TextColumn get effectiveFrom => text()();
}

@DataClassName('ProductStockRow')
class ProductStock extends Table {
  IntColumn get productId =>
      integer().references(Products, #id, onDelete: KeyAction.restrict)();
  IntColumn get quantityScaled => integer().withDefault(const Constant(0))();
  IntColumn get averageCost => integer().withDefault(const Constant(0))();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {productId};
}

@DataClassName('CustomerRow')
class Customers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get phone => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isWalkIn => boolean().withDefault(const Constant(false))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@DataClassName('SupplierRow')
class Suppliers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get notes => text().nullable()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

/// Append-only ledger of changes to what a customer owes the store.
/// The customer balance is always reconstructible by summing this table.
@DataClassName('CustomerAccountEntryRow')
class CustomerAccountEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get customerId =>
      integer().references(Customers, #id, onDelete: KeyAction.restrict)();
  TextColumn get direction => text()();
  IntColumn get amountMinor => integer()();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  TextColumn get referenceType => text()();
  IntColumn get referenceId => integer().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('SupplierAccountEntryRow')
class SupplierAccountEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get supplierId =>
      integer().references(Suppliers, #id, onDelete: KeyAction.restrict)();
  TextColumn get direction => text()();
  IntColumn get amountMinor => integer()();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  TextColumn get referenceType => text()();
  IntColumn get referenceId => integer().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('SaleRow')
class Sales extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get invoiceNo => text().unique()();
  IntColumn get customerId =>
      integer().nullable().references(Customers, #id, onDelete: KeyAction.restrict)();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  IntColumn get subtotal => integer().withDefault(const Constant(0))();
  IntColumn get lineDiscountTotal => integer().withDefault(const Constant(0))();
  IntColumn get invoiceDiscount => integer().withDefault(const Constant(0))();
  IntColumn get total => integer().withDefault(const Constant(0))();
  IntColumn get paidAmount => integer().withDefault(const Constant(0))();
  IntColumn get costTotal => integer().withDefault(const Constant(0))();
  IntColumn get profit => integer().withDefault(const Constant(0))();
  IntColumn get baseSubtotal => integer().withDefault(const Constant(0))();
  IntColumn get baseTotal => integer().withDefault(const Constant(0))();
  IntColumn get basePaidAmount => integer().withDefault(const Constant(0))();
  IntColumn get baseCostTotal => integer().withDefault(const Constant(0))();
  TextColumn get status => text()();
  IntColumn get cashSessionId => integer().nullable()();
  IntColumn get userId => integer().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@DataClassName('SaleItemRow')
class SaleItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get saleId =>
      integer().references(Sales, #id, onDelete: KeyAction.cascade)();
  IntColumn get productId =>
      integer().references(Products, #id, onDelete: KeyAction.restrict)();
  TextColumn get productNameSnapshot => text()();
  TextColumn get skuSnapshot => text().nullable()();
  IntColumn get quantityScaled => integer()();
  IntColumn get unitPrice => integer()();
  // Weighted-average cost snapshot: historical profit must not change when a
  // later purchase changes the product's current average cost.
  IntColumn get unitCost => integer()();
  IntColumn get lineDiscount => integer().withDefault(const Constant(0))();
  IntColumn get total => integer()();
  IntColumn get costTotal => integer().withDefault(const Constant(0))();
}

@DataClassName('SalePaymentRow')
class SalePayments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get saleId =>
      integer().references(Sales, #id, onDelete: KeyAction.cascade)();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  TextColumn get paymentMethod => text()();
  IntColumn get amount => integer()();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  IntColumn get baseAmount => integer()();
  IntColumn get cashSessionId => integer().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('SalesReturnRow')
class SalesReturns extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get returnNo => text().unique()();
  IntColumn get saleId =>
      integer().references(Sales, #id, onDelete: KeyAction.restrict)();
  IntColumn get customerId =>
      integer().nullable().references(Customers, #id, onDelete: KeyAction.restrict)();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  IntColumn get total => integer()();
  IntColumn get costTotal => integer().withDefault(const Constant(0))();
  // 'refund' returns cash to the customer; 'credit' reduces their balance.
  TextColumn get settlement => text()();
  TextColumn get status => text()();
  TextColumn get reason => text().nullable()();
  IntColumn get cashSessionId => integer().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('SalesReturnItemRow')
class SalesReturnItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get salesReturnId =>
      integer().references(SalesReturns, #id, onDelete: KeyAction.cascade)();
  IntColumn get saleItemId =>
      integer().references(SaleItems, #id, onDelete: KeyAction.restrict)();
  IntColumn get productId =>
      integer().references(Products, #id, onDelete: KeyAction.restrict)();
  IntColumn get quantityScaled => integer()();
  IntColumn get unitPrice => integer()();
  IntColumn get unitCost => integer()();
  IntColumn get total => integer()();
}

@DataClassName('PurchaseRow')
class Purchases extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get invoiceNo => text().unique()();
  IntColumn get supplierId =>
      integer().nullable().references(Suppliers, #id, onDelete: KeyAction.restrict)();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  IntColumn get subtotal => integer().withDefault(const Constant(0))();
  IntColumn get discount => integer().withDefault(const Constant(0))();
  IntColumn get additionalCost => integer().withDefault(const Constant(0))();
  IntColumn get total => integer().withDefault(const Constant(0))();
  IntColumn get paidAmount => integer().withDefault(const Constant(0))();
  IntColumn get baseTotal => integer().withDefault(const Constant(0))();
  IntColumn get basePaidAmount => integer().withDefault(const Constant(0))();
  TextColumn get status => text()();
  IntColumn get cashSessionId => integer().nullable()();
  IntColumn get userId => integer().nullable()();
  TextColumn get supplierReference => text().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@DataClassName('PurchaseItemRow')
class PurchaseItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get purchaseId =>
      integer().references(Purchases, #id, onDelete: KeyAction.cascade)();
  IntColumn get productId =>
      integer().references(Products, #id, onDelete: KeyAction.restrict)();
  TextColumn get productNameSnapshot => text()();
  IntColumn get quantityScaled => integer()();
  IntColumn get unitCost => integer()();
  IntColumn get lineDiscount => integer().withDefault(const Constant(0))();
  IntColumn get total => integer()();
  // Stock state immediately before this line, so a posted purchase can be
  // reversed without recomputing the whole history.
  IntColumn get previousAverageCost => integer().withDefault(const Constant(0))();
  IntColumn get previousQuantityScaled => integer().withDefault(const Constant(0))();
}

@DataClassName('PurchasePaymentRow')
class PurchasePayments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get purchaseId =>
      integer().references(Purchases, #id, onDelete: KeyAction.cascade)();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  TextColumn get paymentMethod => text()();
  IntColumn get amount => integer()();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  IntColumn get baseAmount => integer()();
  IntColumn get cashSessionId => integer().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('PurchaseReturnRow')
class PurchaseReturns extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get returnNo => text().unique()();
  IntColumn get purchaseId =>
      integer().references(Purchases, #id, onDelete: KeyAction.restrict)();
  IntColumn get supplierId =>
      integer().nullable().references(Suppliers, #id, onDelete: KeyAction.restrict)();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  IntColumn get total => integer()();
  TextColumn get settlement => text()();
  TextColumn get status => text()();
  TextColumn get reason => text().nullable()();
  IntColumn get cashSessionId => integer().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('PurchaseReturnItemRow')
class PurchaseReturnItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get purchaseReturnId =>
      integer().references(PurchaseReturns, #id, onDelete: KeyAction.cascade)();
  IntColumn get purchaseItemId =>
      integer().references(PurchaseItems, #id, onDelete: KeyAction.restrict)();
  IntColumn get productId =>
      integer().references(Products, #id, onDelete: KeyAction.restrict)();
  IntColumn get quantityScaled => integer()();
  IntColumn get unitCost => integer()();
  IntColumn get total => integer()();
}

@DataClassName('InventoryMovementRow')
class InventoryMovements extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId =>
      integer().references(Products, #id, onDelete: KeyAction.restrict)();
  TextColumn get movementType => text()();
  // Signed: positive increases stock, negative decreases it.
  IntColumn get quantityScaled => integer()();
  IntColumn get balanceAfterScaled => integer()();
  TextColumn get referenceType => text()();
  IntColumn get referenceId => integer().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('StockAdjustmentRow')
class StockAdjustments extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get adjustmentNo => text().unique()();
  TextColumn get reason => text()();
  TextColumn get notes => text().nullable()();
  IntColumn get userId => integer().nullable()();
  TextColumn get status => text()();
  TextColumn get createdAt => text()();
}

@DataClassName('StockAdjustmentItemRow')
class StockAdjustmentItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get stockAdjustmentId =>
      integer().references(StockAdjustments, #id, onDelete: KeyAction.cascade)();
  IntColumn get productId =>
      integer().references(Products, #id, onDelete: KeyAction.restrict)();
  // Positive for adjustment in, negative for adjustment out.
  IntColumn get quantityScaled => integer()();
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();
}

@DataClassName('CustomerPaymentRow')
class CustomerPayments extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get paymentNo => text().unique()();
  IntColumn get customerId =>
      integer().references(Customers, #id, onDelete: KeyAction.restrict)();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  TextColumn get paymentMethod => text()();
  IntColumn get amount => integer()();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  IntColumn get baseAmount => integer()();
  IntColumn get cashSessionId => integer().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('SupplierPaymentRow')
class SupplierPayments extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get paymentNo => text().unique()();
  IntColumn get supplierId =>
      integer().references(Suppliers, #id, onDelete: KeyAction.restrict)();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  TextColumn get paymentMethod => text()();
  IntColumn get amount => integer()();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  IntColumn get baseAmount => integer()();
  IntColumn get cashSessionId => integer().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('ExpenseCategoryRow')
class ExpenseCategories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get code => text().unique()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
}

@DataClassName('ExpenseRow')
class Expenses extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get expenseNo => text().unique()();
  IntColumn get categoryId =>
      integer().nullable().references(ExpenseCategories, #id, onDelete: KeyAction.restrict)();
  TextColumn get description => text()();
  IntColumn get amount => integer()();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  IntColumn get baseAmount => integer()();
  TextColumn get paymentMethod => text()();
  IntColumn get cashSessionId => integer().nullable()();
  IntColumn get supplierId =>
      integer().nullable().references(Suppliers, #id, onDelete: KeyAction.restrict)();
  TextColumn get notes => text().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('CashSessionRow')
class CashSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get openingBalance => integer()();
  IntColumn get closingBalance => integer().nullable()();
  IntColumn get expectedCash => integer().nullable()();
  IntColumn get actualCash => integer().nullable()();
  IntColumn get difference => integer().nullable()();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get userId => integer().nullable()();
  TextColumn get status => text()();
  TextColumn get notes => text().nullable()();
  TextColumn get openedAt => text()();
  TextColumn get closedAt => text().nullable()();
}

@DataClassName('CashTransactionRow')
class CashTransactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get sessionId =>
      integer().references(CashSessions, #id, onDelete: KeyAction.restrict)();
  TextColumn get transactionType => text()();
  // Signed base-currency minor units: positive is cash in, negative cash out.
  IntColumn get amountBase => integer()();
  IntColumn get currencyId =>
      integer().references(Currencies, #id, onDelete: KeyAction.restrict)();
  IntColumn get originalAmount => integer()();
  IntColumn get exchangeRateNumerator => integer().withDefault(const Constant(1))();
  IntColumn get exchangeRateDenominator => integer().withDefault(const Constant(1))();
  TextColumn get referenceType => text().nullable()();
  IntColumn get referenceId => integer().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('UserRow')
class Users extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get displayName => text()();
  TextColumn get username => text().unique()();
  // Only the derived hash is stored; the PIN itself is never persisted.
  TextColumn get pinHash => text().nullable()();
  TextColumn get pinSalt => text().nullable()();
  TextColumn get pinAlgorithm => text().nullable()();
  BoolColumn get isOwner => boolean().withDefault(const Constant(true))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
}

@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DataClassName('AuditLogRow')
class AuditLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get action => text()();
  TextColumn get entityType => text()();
  IntColumn get entityId => integer().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get payload => text().nullable()();
  IntColumn get userId => integer().nullable()();
  TextColumn get createdAt => text()();
}

@DataClassName('BackupHistoryRow')
class BackupHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get filePath => text()();
  IntColumn get fileSizeBytes => integer()();
  TextColumn get direction => text()();
  TextColumn get status => text()();
  TextColumn get checksum => text().nullable()();
  TextColumn get message => text().nullable()();
  TextColumn get createdAt => text()();
}

/// Monotonic counters for human-readable document numbers.
/// Stored in the database so numbering survives restarts and cannot collide.
@DataClassName('DocumentSequenceRow')
class DocumentSequences extends Table {
  TextColumn get name => text()();
  IntColumn get currentValue => integer().withDefault(const Constant(0))();
  TextColumn get prefix => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {name};
}

/// Guards against processing the same critical operation twice (for example a
/// double-tapped "Complete sale" or a retried payment submission).
@DataClassName('IdempotencyKeyRow')
class IdempotencyKeys extends Table {
  TextColumn get key => text()();
  TextColumn get operation => text()();
  IntColumn get resultId => integer().nullable()();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {key};
}
