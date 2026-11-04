import 'package:flutter/foundation.dart';

/// A paper width a thermal printer can take.
enum PaperWidth {
  mm58(58, 32),
  mm80(80, 48);

  const PaperWidth(this.millimetres, this.charactersPerLine);

  final int millimetres;

  /// Printable characters per line at the default font, used for wrapping.
  final int charactersPerLine;
}

/// How a printer is reached.
enum PrinterConnection {
  bluetooth('bluetooth'),
  usb('usb'),
  network('network');

  const PrinterConnection(this.wireValue);

  final String wireValue;

  static PrinterConnection fromWire(String value) => values.firstWhere(
        (connection) => connection.wireValue == value,
        orElse: () => throw ArgumentError('Unknown PrinterConnection: $value'),
      );
}

/// A printer the application can talk to.
@immutable
class PrinterDevice {
  const PrinterDevice({
    required this.id,
    required this.name,
    required this.connection,
    this.address,
    this.isDefault = false,
  });

  final String id;
  final String name;
  final PrinterConnection connection;

  /// A MAC address, a USB path or a host and port, depending on the connection.
  final String? address;

  final bool isDefault;

  @override
  bool operator ==(Object other) => other is PrinterDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PrinterDevice($id, $name, ${connection.wireValue})';
}

/// How a receipt is laid out.
@immutable
class ReceiptConfig {
  const ReceiptConfig({
    this.paperWidth = PaperWidth.mm80,
    this.copies = 1,
    this.openCashDrawer = false,
    this.showLogo = false,
    this.footer,
  });

  final PaperWidth paperWidth;
  final int copies;
  final bool openCashDrawer;
  final bool showLogo;
  final String? footer;

  ReceiptConfig copyWith({
    PaperWidth? paperWidth,
    int? copies,
    bool? openCashDrawer,
    bool? showLogo,
    String? footer,
  }) {
    return ReceiptConfig(
      paperWidth: paperWidth ?? this.paperWidth,
      copies: copies ?? this.copies,
      openCashDrawer: openCashDrawer ?? this.openCashDrawer,
      showLogo: showLogo ?? this.showLogo,
      footer: footer ?? this.footer,
    );
  }
}

/// One printed line of a receipt.
@immutable
class ReceiptLine {
  const ReceiptLine({
    required this.name,
    required this.quantityText,
    required this.unitPriceText,
    required this.totalText,
    this.discountText,
  });

  final String name;
  final String quantityText;
  final String unitPriceText;
  final String totalText;
  final String? discountText;
}

/// A payment shown on a receipt.
@immutable
class ReceiptPayment {
  const ReceiptPayment({
    required this.methodLabel,
    required this.amountText,
    this.currencyCode,
  });

  final String methodLabel;
  final String amountText;
  final String? currencyCode;
}

/// A fully formatted receipt, ready to be rendered.
///
/// The builder does the formatting once, here, so every printer adapter receives
/// the same text and a receipt cannot look different depending on which
/// connection happens to be used.
@immutable
class Receipt {
  const Receipt({
    required this.invoiceNo,
    required this.dateTimeText,
    required this.storeName,
    required this.lines,
    required this.subtotalText,
    required this.totalText,
    required this.payments,
    this.cashierName,
    this.customerName,
    this.storeAddress,
    this.storePhone,
    this.taxNumber,
    this.discountText,
    this.paidText,
    this.outstandingText,
    this.currencyCode,
    this.footer,
    this.isReprint = false,
    this.voided = false,
  });

  final String invoiceNo;
  final String dateTimeText;
  final String storeName;
  final String? storeAddress;
  final String? storePhone;
  final String? taxNumber;
  final String? cashierName;
  final String? customerName;
  final List<ReceiptLine> lines;
  final String subtotalText;
  final String? discountText;
  final String totalText;
  final String? paidText;
  final String? outstandingText;
  final String? currencyCode;
  final List<ReceiptPayment> payments;
  final String? footer;

  /// True when this is a copy of an earlier sale. A reprint never records a new
  /// sale; it only marks the paper.
  final bool isReprint;

  final bool voided;
}
