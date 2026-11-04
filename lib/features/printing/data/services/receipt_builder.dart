import 'package:intl/intl.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/constants/enums.dart';
import '../../../../core/database/settings_service.dart';
import '../../../../core/money/money.dart';
import '../../../../core/money/quantity.dart';
import '../../../../infrastructure/printing/printer_models.dart';
import '../../../sales/domain/entities/sale.dart';

/// Turns a stored sale into a formatted [Receipt].
///
/// Everything the receipt shows comes from the sale record and the settings, not
/// from whatever is currently on screen. A reprint therefore produces the same
/// paper as the original, even days later, and never depends on the cart that
/// happens to be open.
class ReceiptBuilder {
  ReceiptBuilder(this._settings);

  final SettingsService _settings;

  /// Builds the receipt for a sale.
  ///
  /// [isReprint] marks a copy. A reprint never writes a new sale; it only changes
  /// the marking on the paper.
  Future<Receipt> build(Sale sale, {bool isReprint = false}) async {
    final storeName =
        await _settings.getStringOr(SettingsKeys.storeName, 'StoreFlow POS');
    final storeAddress = await _settings.getString(SettingsKeys.storeAddress);
    final storePhone = await _settings.getString(SettingsKeys.storePhone);
    final taxNumber = await _settings.getString(SettingsKeys.storeTaxNumber);
    final footer = await _settings.getString(SettingsKeys.receiptFooter);

    final digits = sale.currencyDecimalDigits;
    String money(int minor) =>
        Money(minor, decimalDigits: digits).toDecimalString();

    final lines = <ReceiptLine>[
      for (final line in sale.lines)
        ReceiptLine(
          name: line.productName,
          quantityText: _formatQuantity(line.quantityScaled),
          unitPriceText: money(line.unitPriceMinor),
          totalText: money(line.netMinor),
          discountText: line.lineDiscountMinor > 0
              ? money(line.lineDiscountMinor)
              : null,
        ),
    ];

    final payments = <ReceiptPayment>[
      for (final payment in sale.payments)
        ReceiptPayment(
          methodLabel: _methodLabel(payment.paymentMethod),
          amountText: Money(
            payment.amountMinor,
            decimalDigits: digits,
          ).toDecimalString(),
        ),
    ];

    return Receipt(
      invoiceNo: sale.invoiceNo,
      dateTimeText: _formatTimestamp(sale.createdAtStorage),
      storeName: storeName,
      storeAddress: storeAddress,
      storePhone: storePhone,
      taxNumber: taxNumber,
      cashierName: sale.userId == null ? null : 'User #${sale.userId}',
      customerName: sale.customerName,
      lines: lines,
      subtotalText: money(sale.subtotalMinor),
      discountText: sale.invoiceDiscountMinor > 0
          ? money(sale.invoiceDiscountMinor)
          : null,
      totalText: money(sale.totalMinor),
      paidText: money(sale.paidAmountMinor),
      outstandingText:
          sale.baseOutstandingMinor > 0 ? sale.outstanding.toDecimalString() : null,
      currencyCode: sale.currencyCode,
      payments: payments,
      footer: footer,
      isReprint: isReprint,
      voided: sale.status == DocumentStatus.voided,
    );
  }

  /// The receipt layout settings, read from the database.
  Future<ReceiptConfig> config() async {
    final widthText =
        await _settings.getStringOr(SettingsKeys.receiptPaperWidth, '80');
    final copies = await _settings.getInt(SettingsKeys.receiptCopies, fallback: 1);
    final footer = await _settings.getString(SettingsKeys.receiptFooter);
    return ReceiptConfig(
      paperWidth: widthText == '58' ? PaperWidth.mm58 : PaperWidth.mm80,
      copies: copies < 1 ? 1 : copies,
      footer: footer,
    );
  }

  /// Formats a stored UTC timestamp in the local zone for display.
  String _formatTimestamp(String storageTimestamp) {
    final parsed = DateTime.parse(storageTimestamp).toLocal();
    return DateFormat('yyyy-MM-dd HH:mm').format(parsed);
  }

  /// Formats a scaled quantity, trimming trailing zeros so a whole number of
  /// units prints as `2` rather than `2.000`.
  String _formatQuantity(int scaledValue) {
    return Quantity(scaledValue).toDisplayString();
  }

  String _methodLabel(PaymentMethod method) => switch (method) {
        PaymentMethod.cash => 'Cash',
        PaymentMethod.bankTransfer => 'Bank transfer',
        PaymentMethod.electronic => 'Electronic',
        PaymentMethod.credit => 'Credit',
      };
}
