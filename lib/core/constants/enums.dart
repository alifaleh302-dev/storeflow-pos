/// Shared domain enumerations.
///
/// Each enum has a stable [wireValue] used as the persisted text in SQLite.
/// Never rename a [wireValue]: the database stores these strings, and changing
/// one would silently reinterpret historical rows.
library;

/// Lifecycle of a posted financial document (sale, purchase, return).
enum DocumentStatus {
  draft('draft'),
  posted('posted'),
  voided('voided');

  const DocumentStatus(this.wireValue);

  final String wireValue;

  static DocumentStatus fromWire(String value) => values.firstWhere(
        (status) => status.wireValue == value,
        orElse: () => throw ArgumentError('Unknown DocumentStatus: $value'),
      );
}

/// How a payment was tendered. Split payments are modelled as several
/// allocations rather than a distinct method, so they are not listed here.
enum PaymentMethod {
  cash('cash'),
  bankTransfer('bank_transfer'),
  electronic('electronic'),
  credit('credit');

  const PaymentMethod(this.wireValue);

  final String wireValue;

  /// Credit is a promise to pay, so it never moves physical cash.
  bool get isCash => this == PaymentMethod.cash;

  /// Only credit affects a customer's outstanding balance.
  bool get isCredit => this == PaymentMethod.credit;

  static PaymentMethod fromWire(String value) => values.firstWhere(
        (method) => method.wireValue == value,
        orElse: () => throw ArgumentError('Unknown PaymentMethod: $value'),
      );
}

/// The reason a stock balance changed. Every inventory movement records one.
enum MovementType {
  purchase('purchase', 1),
  sale('sale', -1),
  customerReturn('customer_return', 1),
  supplierReturn('supplier_return', -1),
  adjustmentIn('adjustment_in', 1),
  adjustmentOut('adjustment_out', -1),
  damage('damage', -1),
  openingStock('opening_stock', 1);

  const MovementType(this.wireValue, this.direction);

  final String wireValue;

  /// `+1` increases stock, `-1` decreases it. Used to validate the sign of a
  /// movement's quantity so a bug cannot record an inbound sale.
  final int direction;

  static MovementType fromWire(String value) => values.firstWhere(
        (type) => type.wireValue == value,
        orElse: () => throw ArgumentError('Unknown MovementType: $value'),
      );
}

/// What kind of document produced a movement or payment.
enum ReferenceType {
  sale('sale'),
  purchase('purchase'),
  salesReturn('sales_return'),
  purchaseReturn('purchase_return'),
  stockAdjustment('stock_adjustment'),
  customerPayment('customer_payment'),
  supplierPayment('supplier_payment'),
  expense('expense'),
  cashTransaction('cash_transaction'),
  openingStock('opening_stock'),
  manual('manual');

  const ReferenceType(this.wireValue);

  final String wireValue;

  static ReferenceType fromWire(String value) => values.firstWhere(
        (type) => type.wireValue == value,
        orElse: () => throw ArgumentError('Unknown ReferenceType: $value'),
      );
}

/// Direction of an account ledger entry, from the perspective of the account
/// holder's balance owed to the store.
///
/// * [debit] increases what the account holder owes (a credit sale).
/// * [credit] decreases what the account holder owes (a payment or return).
///
/// For supplier accounts the sign convention is mirrored by the service layer
/// so that a positive balance always means "the store owes this party".
enum LedgerDirection {
  debit('debit'),
  credit('credit');

  const LedgerDirection(this.wireValue);

  final String wireValue;

  static LedgerDirection fromWire(String value) => values.firstWhere(
        (direction) => direction.wireValue == value,
        orElse: () => throw ArgumentError('Unknown LedgerDirection: $value'),
      );
}

/// Type of a physical cash movement inside a cash session.
enum CashTransactionType {
  opening('opening'),
  saleReceipt('sale_receipt'),
  customerCollection('customer_collection'),
  expensePayment('expense_payment'),
  supplierPayment('supplier_payment'),
  deposit('deposit'),
  withdrawal('withdrawal'),
  adjustment('adjustment');

  const CashTransactionType(this.wireValue);

  final String wireValue;

  /// `+1` is cash in, `-1` is cash out.
  int get direction => switch (this) {
        CashTransactionType.opening ||
        CashTransactionType.saleReceipt ||
        CashTransactionType.customerCollection ||
        CashTransactionType.deposit =>
          1,
        CashTransactionType.expensePayment ||
        CashTransactionType.supplierPayment ||
        CashTransactionType.withdrawal =>
          -1,
        CashTransactionType.adjustment => 0,
      };

  static CashTransactionType fromWire(String value) => values.firstWhere(
        (type) => type.wireValue == value,
        orElse: () => throw ArgumentError('Unknown CashTransactionType: $value'),
      );
}

/// Status of a cash register session.
enum CashSessionStatus {
  open('open'),
  closed('closed');

  const CashSessionStatus(this.wireValue);

  final String wireValue;

  static CashSessionStatus fromWire(String value) => values.firstWhere(
        (status) => status.wireValue == value,
        orElse: () => throw ArgumentError('Unknown CashSessionStatus: $value'),
      );
}

/// Kind of document a stock adjustment represents.
enum StockAdjustmentReason {
  count('count'),
  damage('damage'),
  loss('loss'),
  opening('opening'),
  correction('correction');

  const StockAdjustmentReason(this.wireValue);

  final String wireValue;

  static StockAdjustmentReason fromWire(String value) => values.firstWhere(
        (reason) => reason.wireValue == value,
        orElse: () => throw ArgumentError('Unknown StockAdjustmentReason: $value'),
      );
}
