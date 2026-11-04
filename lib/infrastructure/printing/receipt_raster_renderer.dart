import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'esc_pos_builder.dart';
import 'printer_models.dart';

/// Renders a receipt to a monochrome bitmap for ESC/POS raster printing.
///
/// Most thermal printers cannot render Arabic. Rather than send bytes they will
/// print as noise, the receipt is drawn with Flutter, which shapes Arabic and
/// orders right-to-left text correctly, and the result is reduced to one bit per
/// pixel and sent as an image.
///
/// The width in dots follows the paper: 80mm paper is 576 dots across and 58mm
/// paper is 384, which are the standard resolutions for those widths.
class ReceiptRasterRenderer {
  const ReceiptRasterRenderer();

  /// Dots across the paper.
  static int dotsFor(PaperWidth width) =>
      width == PaperWidth.mm58 ? 384 : 576;

  /// Renders [receipt] and returns a bitmap ready for the printer.
  Future<RasterImage> render(Receipt receipt, PaperWidth paperWidth) async {
    final widthDots = dotsFor(paperWidth);
    final painter =
        _ReceiptPainter(receipt: receipt, width: widthDots.toDouble());

    // The receipt is laid out before it is drawn, so the image is exactly as tall
    // as its content and no blank tail is sent to the printer.
    final textScale = widthDots / 384.0;
    final heightDots = painter.measure(textScale: textScale).ceil();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, widthDots.toDouble(), heightDots.toDouble()),
      Paint()..color = Colors.white,
    );
    painter.paint(
      canvas,
      Size(widthDots.toDouble(), heightDots.toDouble()),
      textScale: textScale,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(widthDots, heightDots);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    picture.dispose();

    return _toMonochrome(
      byteData!.buffer.asUint8List(),
      width: widthDots,
      height: heightDots,
    );
  }

  /// Reduces RGBA pixels to the 1-bit-per-pixel layout ESC/POS expects.
  ///
  /// A pixel counts as ink when it is darker than the midpoint. The result is
  /// packed most significant bit first within each byte, which is the order the
  /// raster command requires.
  RasterImage _toMonochrome(
    Uint8List rgba, {
    required int width,
    required int height,
  }) {
    final bytesPerRow = (width + 7) ~/ 8;
    final pixels = Uint8List(bytesPerRow * height);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final offset = (y * width + x) * 4;
        final r = rgba[offset];
        final g = rgba[offset + 1];
        final b = rgba[offset + 2];
        final a = rgba[offset + 3];
        // Luma with the conventional weights; transparent counts as white.
        final luma = a < 8 ? 255 : (0.299 * r + 0.587 * g + 0.114 * b);
        if (luma < 128) {
          final byteIndex = y * bytesPerRow + (x >> 3);
          pixels[byteIndex] |= 0x80 >> (x & 7);
        }
      }
    }

    return RasterImage(
      pixels: pixels,
      bytesPerRow: bytesPerRow,
      height: height,
    );
  }
}

/// Draws a receipt as black text on white.
class _ReceiptPainter {
  _ReceiptPainter({required this.receipt, required this.width});

  final Receipt receipt;
  final double width;

  static const double margin = 8;
  static const double lineHeight = 22;

  /// The height the receipt needs at the given text scale.
  double measure({required double textScale}) =>
      _layout(textScale).length * lineHeight * textScale + margin * 2;

  void paint(Canvas canvas, Size size, {required double textScale}) {
    final lines = _layout(textScale);
    var y = margin;
    for (final line in lines) {
      final painter = TextPainter(
        text: TextSpan(
          text: line.text,
          style: TextStyle(
            color: Colors.black,
            fontSize: line.size * textScale,
            fontWeight: line.bold ? FontWeight.bold : FontWeight.normal,
            fontFamily: 'Tajawal',
            height: 1.2,
          ),
        ),
        textDirection: line.rtl ? TextDirection.rtl : TextDirection.ltr,
        textAlign: line.align,
      )..layout(maxWidth: width - margin * 2);
      painter.paint(canvas, Offset(margin, y));
      y += lineHeight * textScale;
    }
  }

  /// Flattens the receipt into drawable lines.
  ///
  /// Arabic fields are right-aligned and Latin fields left-aligned, which is what
  /// makes a mixed receipt readable. The alignment is chosen per line from the
  /// text itself rather than from the application locale, so an English product
  /// name on an Arabic receipt still reads correctly.
  List<_DrawableLine> _layout(double textScale) {
    final result = <_DrawableLine>[];
    void add(
      String text, {
      double size = 11,
      bool bold = false,
      TextAlign align = TextAlign.left,
    }) {
      if (text.isEmpty) return;
      result.add(
        _DrawableLine(
          text: text,
          size: size,
          bold: bold,
          align: align,
          rtl: EscPosBuilder.containsArabic(text),
        ),
      );
    }

    add(receipt.storeName, size: 16, bold: true, align: TextAlign.center);
    if (receipt.storeAddress != null) {
      add(receipt.storeAddress!, align: TextAlign.center);
    }
    if (receipt.storePhone != null) {
      add(receipt.storePhone!, align: TextAlign.center);
    }
    if (receipt.taxNumber != null) {
      add('Tax No: ${receipt.taxNumber}', align: TextAlign.center);
    }
    add('--------------------------------');
    add('Invoice: ${receipt.invoiceNo}');
    add('Date: ${receipt.dateTimeText}');
    if (receipt.customerName != null) add('Customer: ${receipt.customerName}');
    if (receipt.isReprint) add('*** REPRINT ***', align: TextAlign.center);
    if (receipt.voided) add('*** VOID ***', align: TextAlign.center);
    add('--------------------------------');

    for (final line in receipt.lines) {
      add(line.name, bold: true);
      add('${line.quantityText} x ${line.unitPriceText} = ${line.totalText}');
      if (line.discountText != null) add('  Discount: ${line.discountText}');
    }

    add('--------------------------------');
    add('Subtotal: ${receipt.subtotalText}');
    if (receipt.discountText != null) add('Discount: ${receipt.discountText}');
    add('TOTAL: ${receipt.totalText}', size: 14, bold: true);
    if (receipt.paidText != null) add('Paid: ${receipt.paidText}');
    if (receipt.outstandingText != null) {
      add('Balance: ${receipt.outstandingText}');
    }
    for (final payment in receipt.payments) {
      add('${payment.methodLabel}: ${payment.amountText}');
    }
    if (receipt.footer != null) {
      add('--------------------------------');
      add(receipt.footer!, align: TextAlign.center);
    }
    return result;
  }
}

class _DrawableLine {
  const _DrawableLine({
    required this.text,
    required this.size,
    required this.bold,
    required this.align,
    required this.rtl,
  });

  final String text;
  final double size;
  final bool bold;
  final TextAlign align;
  final bool rtl;
}
