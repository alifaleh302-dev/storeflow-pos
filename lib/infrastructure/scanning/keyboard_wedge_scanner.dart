import 'package:flutter/services.dart';

import 'barcode_scanner_service.dart';

/// Reads a USB HID barcode scanner on Windows.
///
/// A USB scanner is a keyboard as far as the operating system is concerned: it
/// types the digits of the barcode and then presses Enter. There is no API that
/// says "this keystroke came from a scanner", so this adapter reconstructs the
/// reading from the timing and the terminator:
///
/// * a scanner types far faster than a person, so keystrokes arriving within
///   [maxInterKeyDelay] of each other are treated as one burst;
/// * a scanner ends with Enter, which flushes the burst as a reading;
/// * a pause longer than [maxInterKeyDelay] abandons the burst, so ordinary typing
///   in a form field is not mistaken for a scan.
///
/// The caller is expected to keep the focus off text fields while scanning, which
/// the POS screen does. [submitManual] remains available for a typed code.
class KeyboardWedgeScanner extends BaseBarcodeScannerService {
  KeyboardWedgeScanner({
    super.duplicateWindow,
    this.maxInterKeyDelay = const Duration(milliseconds: 50),
    this.minLength = 4,
  });

  /// The longest gap between two keystrokes that still counts as one scan.
  final Duration maxInterKeyDelay;

  /// The shortest burst treated as a barcode. Guards against a stray keystroke
  /// followed by Enter being read as a one-character barcode.
  final int minLength;

  final StringBuffer _buffer = StringBuffer();
  DateTime? _lastKeystroke;
  bool _handling = false;

  @override
  bool get isSupported => true;

  @override
  Future<void> onStart() async {
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  Future<void> onStop() async {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _buffer.clear();
    _lastKeystroke = null;
  }

  bool _onKey(KeyEvent event) {
    if (!isRunning || _handling) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    final now = DateTime.now();
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _flush(now);
      // Consumed so the Enter does not also submit whatever form has focus.
      return _buffer.isEmpty && _lastKeystroke != null;
    }

    final character = event.character;
    if (character == null || character.isEmpty) {
      // A key with no character, such as Shift, does not interrupt a scan but
      // also does not add to it.
      return false;
    }

    // A gap this long means a human is typing, not a scanner.
    if (_lastKeystroke != null &&
        now.difference(_lastKeystroke!) > maxInterKeyDelay) {
      _buffer.clear();
    }
    _buffer.write(character);
    _lastKeystroke = now;
    return false;
  }

  void _flush(DateTime now) {
    final value = _buffer.toString().trim();
    final last = _lastKeystroke;
    _buffer.clear();
    _lastKeystroke = null;

    if (last == null) return;
    // A burst that took too long was probably typing, not a scan.
    if (now.difference(last) > maxInterKeyDelay) return;
    if (value.length < minLength) return;

    _handling = true;
    try {
      emit(value, _guessFormat(value));
    } finally {
      _handling = false;
    }
  }

  /// Guesses the format from the length and the check digit.
  ///
  /// The length is what identifies these formats in practice, so this is a
  /// best-effort label. A wrong label never changes which product is found,
  /// because lookup is by the value itself.
  static BarcodeFormat _guessFormat(String value) {
    if (value.length == 13 && _hasValidEan13CheckDigit(value)) {
      return BarcodeFormat.ean13;
    }
    if (value.length == 12) return BarcodeFormat.upcA;
    if (value.length == 8) return BarcodeFormat.ean8;
    return BarcodeFormat.code128;
  }

  /// Verifies the EAN-13 check digit, so a mistyped number is not labelled as a
  /// valid EAN-13.
  static bool _hasValidEan13CheckDigit(String value) {
    if (value.length != 13) return false;
    var sum = 0;
    for (var i = 0; i < 12; i++) {
      final digit = int.tryParse(value[i]);
      if (digit == null) return false;
      sum += (i.isEven) ? digit : digit * 3;
    }
    final check = (10 - (sum % 10)) % 10;
    return check == int.tryParse(value[12]);
  }
}

/// A scanner that is not available on the running platform.
///
/// Reports why it cannot run instead of failing silently, which is what the
/// specification requires for hardware a platform does not support.
class UnsupportedScanner extends BaseBarcodeScannerService {
  UnsupportedScanner(this._reason);

  final String _reason;

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason => _reason;

  /// Manual entry still works everywhere, so it is not blocked by this class.
  @override
  void submitManual(
    String value, {
    BarcodeFormat format = BarcodeFormat.code128,
  }) {
    emit(value, format);
  }
}
