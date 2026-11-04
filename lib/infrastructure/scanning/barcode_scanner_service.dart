import 'dart:async';

import 'package:flutter/foundation.dart';

/// Barcode formats the application can be asked to recognise.
enum BarcodeFormat {
  ean13('ean13'),
  ean8('ean8'),
  upcA('upca'),
  upcE('upce'),
  code128('code128'),
  code39('code39'),
  qrCode('qrcode');

  const BarcodeFormat(this.wireValue);

  final String wireValue;
}

/// A barcode read from a camera or a keyboard-wedge scanner.
@immutable
class ScanResult {
  const ScanResult({
    required this.value,
    required this.format,
    required this.scannedAt,
    this.isDuplicate = false,
  });

  /// The raw characters of the barcode, trimmed.
  final String value;

  final BarcodeFormat format;

  final DateTime scannedAt;

  /// True when this reading was suppressed because the same value arrived again
  /// within the duplicate window.
  final bool isDuplicate;

  ScanResult asDuplicate() => ScanResult(
        value: value,
        format: format,
        scannedAt: scannedAt,
        isDuplicate: true,
      );
}

/// Supplies barcode readings.
///
/// The two platforms behave very differently: Android reads frames from a camera,
/// while a Windows machine sees a USB scanner as a keyboard that types digits and
/// presses Enter. Both are hidden behind this interface so the POS screen treats
/// them the same way.
abstract class BarcodeScannerService {
  /// Whether this scanner works on the running platform.
  bool get isSupported;

  /// Why it is not supported, for display when [isSupported] is false.
  String? get unsupportedReason;

  /// A stream of readings. Ends when the scanner is stopped.
  Stream<ScanResult> get scans;

  /// Starts scanning. On Android this opens the camera; on Windows it begins
  /// listening to the keyboard.
  Future<void> start();

  /// Stops scanning and releases any hardware.
  Future<void> stop();

  /// Handles a barcode typed by hand, which is always available as a fallback.
  void submitManual(String value, {BarcodeFormat format = BarcodeFormat.code128});
}

/// Shared duplicate suppression and stream plumbing.
///
/// A camera sees the same barcode in many consecutive frames, and a keyboard
/// scanner can repeat if a key is held. Emitting every reading would add the same
/// product to the cart several times, so a repeat of the same value inside
/// [duplicateWindow] is marked as a duplicate rather than silently dropped, which
/// lets the caller decide what to do.
abstract class BaseBarcodeScannerService implements BarcodeScannerService {
  BaseBarcodeScannerService({
    this.duplicateWindow = const Duration(milliseconds: 1500),
  });

  /// How long the same barcode is treated as a repeat.
  final Duration duplicateWindow;

  final List<void Function()> _listeners = <void Function()>[];

  final StreamController<ScanResult> _controller =
      StreamController<ScanResult>.broadcast();

  String? _lastValue;
  DateTime? _lastAt;
  bool _running = false;

  /// Whether scanning is currently active.
  bool get isRunning => _running;

  /// Platform hooks. A subclass that needs no setup can leave these alone.
  @protected
  Future<void> onStart() async {}

  @protected
  Future<void> onStop() async {}

  @override
  bool get isSupported => true;

  @override
  String? get unsupportedReason => null;

  @override
  Stream<ScanResult> get scans => _controller.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    if (!isSupported) {
      throw StateError(
        unsupportedReason ?? 'Barcode scanning is not supported on this platform',
      );
    }
    await onStart();
    _running = true;
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    await onStop();
    _running = false;
    _lastValue = null;
    _lastAt = null;
  }

  @override
  void submitManual(
    String value, {
    BarcodeFormat format = BarcodeFormat.code128,
  }) {
    _emit(value, format);
  }

  /// Emits a reading from the platform, applying duplicate suppression.
  @protected
  void emit(String value, BarcodeFormat format) {
    _emit(value, format);
  }

  void _emit(String value, BarcodeFormat format) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;

    final now = DateTime.now();
    final isDuplicate = _lastValue == trimmed &&
        _lastAt != null &&
        now.difference(_lastAt!) < duplicateWindow;

    // A duplicate is still reported, so the caller can ignore it deliberately
    // rather than being left to wonder whether the scan registered.
    final result = ScanResult(
      value: trimmed,
      format: format,
      scannedAt: now,
      isDuplicate: isDuplicate,
    );

    if (!isDuplicate) {
      _lastValue = trimmed;
      _lastAt = now;
    }
    if (!_controller.isClosed) _controller.add(result);
  }

  /// Registers a callback for readings, returning a disposer.
  void addListener(void Function() listener) => _listeners.add(listener);

  @protected
  void notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// Closes the stream. Called when the service is disposed.
  Future<void> dispose() async {
    await stop();
    _listeners.clear();
    if (!_controller.isClosed) await _controller.close();
  }
}
