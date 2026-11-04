import 'package:flutter/foundation.dart';

import 'printer_models.dart';

/// Raised when a printer operation cannot be completed.
///
/// A printing failure is reported, never swallowed. It must not roll back a
/// completed sale: by the time a receipt is printed the invoice is already
/// posted, so the failure has to surface to the operator with the invoice intact
/// and reprintable.
class PrinterException implements Exception {
  const PrinterException(this.message, {this.deviceId, this.cause});

  final String message;
  final String? deviceId;
  final Object? cause;

  @override
  String toString() => 'PrinterException: $message'
      '${deviceId == null ? '' : ' (device: $deviceId)'}';
}

/// A printer the application can send a receipt to.
///
/// Each platform supplies its own implementation behind this interface, so the
/// rest of the application never depends on Bluetooth, USB or sockets directly.
abstract class PrinterService {
  /// Printers reachable right now. An empty list is a normal result, not an
  /// error: it usually means nothing is switched on.
  Future<List<PrinterDevice>> discover();

  /// Connects to a printer, making it the target of later prints.
  Future<void> connect(PrinterDevice device);

  /// Sends a receipt to the connected printer.
  Future<void> printReceipt(Receipt receipt, {ReceiptConfig? config});

  /// Releases the connection. Safe to call when nothing is connected.
  Future<void> disconnect();

  /// The printer currently connected, or null.
  PrinterDevice? get connectedDevice;

  /// Whether this adapter can work on the running platform at all.
  ///
  /// Used to show an honest "not supported here" message instead of failing
  /// silently when, for example, a Bluetooth adapter is asked to run on a desktop
  /// that has no Bluetooth stack wired up.
  bool get isSupportedOnThisPlatform;
}

/// A base class that keeps the connected-device bookkeeping in one place.
abstract class BasePrinterService implements PrinterService {
  PrinterDevice? _connected;

  @override
  PrinterDevice? get connectedDevice => _connected;

  /// Records the device as connected. Subclasses call this from [connect] once
  /// they have actually established the link.
  @protected
  void markConnected(PrinterDevice device) {
    _connected = device;
  }

  /// Clears the connected device.
  @protected
  void markDisconnected() {
    _connected = null;
  }

  @override
  Future<void> disconnect() async {
    markDisconnected();
  }
}
