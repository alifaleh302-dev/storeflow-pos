import 'dart:async';
import 'dart:typed_data';

import 'printer_models.dart';
import 'printer_service.dart';

/// A printer adapter that records what it was asked to print.
///
/// Used by tests, and available at runtime so the application can be exercised on
/// a machine with no printer attached. It is never presented as a real printer:
/// [isSupportedOnThisPlatform] is true but [discover] only ever returns the
/// virtual device, and every printed receipt is kept in memory for inspection.
class MockPrinterService extends BasePrinterService {
  MockPrinterService({this.failOnPrint = false});

  /// When true, [printReceipt] throws, so failure handling can be exercised.
  bool failOnPrint;

  /// Every byte stream handed to [printReceipt], in order.
  final List<Uint8List> printedPayloads = <Uint8List>[];

  /// Every receipt handed to [printReceipt], in order.
  final List<Receipt> printedReceipts = <Receipt>[];

  /// The devices [discover] will report.
  List<PrinterDevice> devices = <PrinterDevice>[
    const PrinterDevice(
      id: 'mock-80',
      name: 'Virtual 80mm printer',
      connection: PrinterConnection.network,
      address: '127.0.0.1:9100',
      isDefault: true,
    ),
    const PrinterDevice(
      id: 'mock-58',
      name: 'Virtual 58mm printer',
      connection: PrinterConnection.bluetooth,
      address: '00:00:00:00:00:00',
    ),
  ];

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<List<PrinterDevice>> discover() async => List<PrinterDevice>.of(devices);

  @override
  Future<void> connect(PrinterDevice device) async {
    if (!devices.contains(device)) {
      throw PrinterException(
        'The printer is not available',
        deviceId: device.id,
      );
    }
    markConnected(device);
  }

  @override
  Future<void> printReceipt(Receipt receipt, {ReceiptConfig? config}) async {
    if (connectedDevice == null) {
      throw const PrinterException(
        'No printer is connected. Connect a printer before printing.',
      );
    }
    if (failOnPrint) {
      throw PrinterException(
        'The printer reported an error',
        deviceId: connectedDevice!.id,
      );
    }
    printedReceipts.add(receipt);
    // A short payload stands in for the real byte stream, so callers that only
    // need to know a print happened do not depend on the ESC/POS layout.
    printedPayloads.add(
      Uint8List.fromList(<int>[receipt.invoiceNo.length, receipt.lines.length]),
    );
  }

  @override
  Future<void> disconnect() async {
    markDisconnected();
  }
}

/// A printer adapter for a platform where the connection is not available.
///
/// [discover] returns nothing and [connect] refuses, with a message naming the
/// reason. This is how an unsupported hardware path reports itself rather than
/// appearing to work.
class UnsupportedPrinterService extends BasePrinterService {
  UnsupportedPrinterService(this.connection, this.reason);

  final PrinterConnection connection;
  final String reason;

  @override
  bool get isSupportedOnThisPlatform => false;

  @override
  Future<List<PrinterDevice>> discover() async => const <PrinterDevice>[];

  @override
  Future<void> connect(PrinterDevice device) async {
    throw PrinterException(reason, deviceId: device.id);
  }

  @override
  Future<void> printReceipt(Receipt receipt, {ReceiptConfig? config}) async {
    throw PrinterException(reason);
  }
}
