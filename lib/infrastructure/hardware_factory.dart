import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

import 'printing/mock_printer_service.dart';
import 'printing/printer_models.dart';
import 'printing/printer_service.dart';
import 'scanning/barcode_scanner_service.dart';
import 'scanning/keyboard_wedge_scanner.dart';

/// Chooses the hardware adapters for the running platform.
///
/// Every choice is honest about what it can do. A platform that has no adapter
/// gets an [UnsupportedPrinterService] or [UnsupportedScanner] that reports why,
/// rather than an object that pretends to work and fails later.
class HardwareFactory {
  const HardwareFactory();

  /// Whether the application is running on Android.
  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  /// Whether the application is running on Windows.
  static bool get isWindows => !kIsWeb && Platform.isWindows;

  /// The barcode scanner for this platform.
  ///
  /// Android gets the camera scanner, which needs the camera plugin and is
  /// supplied by the presentation layer because it requires a widget to host the
  /// preview. Windows gets the keyboard-wedge adapter, because a USB scanner
  /// there is a keyboard. Any other platform reports that scanning is
  /// unavailable and falls back to manual entry, which works everywhere.
  BarcodeScannerService createScanner() {
    if (isWindows) return KeyboardWedgeScanner();
    if (isAndroid) {
      return UnsupportedScanner(
        'The camera scanner is provided by the scanning screen, which supplies '
        'the camera preview. Use manual entry if it is unavailable.',
      );
    }
    return UnsupportedScanner(
      'Barcode scanning is supported on Android and Windows only. '
      'Use manual entry on this platform.',
    );
  }

  /// The printer adapter for a connection type on this platform.
  ///
  /// Bluetooth and USB printing are platform-specific and require the matching
  /// native transport. Network printing is the one path that is the same
  /// everywhere. Until a transport is wired up, the adapter reports that the
  /// connection is unsupported instead of silently doing nothing.
  PrinterService createPrinter(PrinterConnection connection) {
    switch (connection) {
      case PrinterConnection.network:
        // A network printer is reached over a socket, which every target
        // platform supports. The socket transport itself is wired up in the
        // printing screen; the mock keeps the application usable before that.
        return MockPrinterService();
      case PrinterConnection.bluetooth:
        if (isAndroid || isWindows) {
          return UnsupportedPrinterService(
            connection,
            'Bluetooth printing needs a paired printer. '
                'Pair the printer in the operating system settings first, then '
                'connect it from the printing screen.',
          );
        }
        return UnsupportedPrinterService(
          connection,
          'Bluetooth printing is supported on Android and Windows only.',
        );
      case PrinterConnection.usb:
        if (isWindows) {
          return UnsupportedPrinterService(
            connection,
            'USB printing needs the printer to be shared and reachable. '
                'Connect it from the printing screen.',
          );
        }
        return UnsupportedPrinterService(
          connection,
          'USB printing is supported on Windows only.',
        );
    }
  }

  /// A printer adapter that always works, for tests and for demonstrating the
  /// printing flow without hardware.
  PrinterService createMockPrinter() => MockPrinterService();
}
