import 'dart:convert';
import 'dart:typed_data';

import 'printer_models.dart';
import 'printer_service.dart';

/// Builds ESC/POS byte streams from a formatted [Receipt].
///
/// ## Arabic on a thermal printer
///
/// Most ESC/POS printers have no Arabic code page, so sending Arabic text as
/// bytes produces garbage or a row of question marks. The builder therefore has
/// two modes:
///
/// * [buildText] emits plain text and is correct for Latin-only receipts.
/// * [buildWithRasterArabic] detects Arabic in any field and, for the whole
///   receipt, renders the text to a monochrome bitmap and prints it with the
///   ESC/POS raster command. Rasterising the entire receipt rather than only the
///   Arabic lines keeps the column alignment consistent, because a mixed
///   receipt would otherwise have two different character widths on one page.
///
/// The raster step needs a rendered image, which the caller supplies, so this
/// class stays free of any rendering dependency and remains testable.
class EscPosBuilder {
  EscPosBuilder({this.paperWidth = PaperWidth.mm80});

  final PaperWidth paperWidth;

  /// ESC @ : reset the printer to its power-on defaults.
  static const List<int> initialise = <int>[0x1B, 0x40];

  /// ESC a 0 : left alignment.
  static const List<int> alignLeft = <int>[0x1B, 0x61, 0x00];

  /// ESC a 1 : centre alignment.
  static const List<int> alignCentre = <int>[0x1B, 0x61, 0x01];

  /// ESC a 2 : right alignment.
  static const List<int> alignRight = <int>[0x1B, 0x61, 0x02];

  /// ESC d 3 : feed three lines before cutting.
  static const List<int> feedAndCut = <int>[0x1B, 0x64, 0x03, 0x1D, 0x56, 0x42, 0x00];

  /// ESC p 0 25 250 : pulse pin 2 of the cash drawer.
  static const List<int> kickCashDrawer = <int>[0x1B, 0x70, 0x00, 0x19, 0xFA];

  /// ESC t 0 : select the character code table the text is encoded in.
  static const List<int> selectCodePageCp437 = <int>[0x1B, 0x74, 0x00];

  /// True when the text contains any Arabic character.
  static bool containsArabic(String text) {
    for (final rune in text.runes) {
      // Arabic, Arabic Supplement and Arabic Presentation Forms.
      if ((rune >= 0x0600 && rune <= 0x06FF) ||
          (rune >= 0x0750 && rune <= 0x077F) ||
          (rune >= 0xFB50 && rune <= 0xFDFF) ||
          (rune >= 0xFE70 && rune <= 0xFEFF)) {
        return true;
      }
    }
    return false;
  }

  /// True when any printable field of the receipt contains Arabic.
  bool receiptContainsArabic(Receipt receipt) {
    final texts = <String>[
      receipt.storeName,
      receipt.storeAddress ?? '',
      receipt.invoiceNo,
      receipt.customerName ?? '',
      receipt.footer ?? '',
      for (final line in receipt.lines) line.name,
      for (final payment in receipt.payments) payment.methodLabel,
    ];
    return texts.any(containsArabic);
  }

  /// Wraps [text] so no line exceeds [width] characters.
  ///
  /// Wrapping is done on word boundaries where possible. A single word longer
  /// than the line is hard-split rather than allowed to overflow, because an
  /// overflowing word on a thermal printer is silently clipped.
  static List<String> wrap(String text, int width) {
    if (width <= 0) return <String>[text];
    final result = <String>[];
    for (final paragraph in text.split('\n')) {
      if (paragraph.isEmpty) {
        result.add('');
        continue;
      }
      var current = StringBuffer();
      for (final word in paragraph.split(' ')) {
        if (current.isEmpty) {
          // A single word too long for the line is split across lines.
          var remaining = word;
          while (remaining.length > width) {
            result.add(remaining.substring(0, width));
            remaining = remaining.substring(width);
          }
          current.write(remaining);
        } else if (current.length + 1 + word.length <= width) {
          current.write(' $word');
        } else {
          result.add(current.toString());
          var remaining = word;
          while (remaining.length > width) {
            result.add(remaining.substring(0, width));
            remaining = remaining.substring(width);
          }
          current = StringBuffer(remaining);
        }
      }
      if (current.isNotEmpty) result.add(current.toString());
    }
    return result;
  }

  /// Lays a left label and a right value on one line of [width] characters.
  static String columns(String left, String right, int width) {
    final gap = width - left.length - right.length;
    if (gap < 1) {
      // Not enough room: the label wins and the value goes on the next line.
      return '$left\n${' ' * (width - right.length).clamp(0, width)}$right';
    }
    return '$left${' ' * gap}$right';
  }

  /// Builds a plain-text receipt.
  ///
  /// Suitable only when no field contains Arabic. Use [buildWithRasterArabic]
  /// when it does.
  Uint8List buildText(Receipt receipt, {ReceiptConfig? config}) {
    final effectiveConfig = config ?? const ReceiptConfig();
    final width = effectiveConfig.paperWidth.charactersPerLine;
    final buffer = BytesBuilder();

    buffer.add(initialise);
    buffer.add(selectCodePageCp437);
    buffer.add(alignCentre);
    buffer.add(utf8.encode('${receipt.storeName}\n'));
    if (receipt.storeAddress != null) {
      buffer.add(utf8.encode('${receipt.storeAddress}\n'));
    }
    if (receipt.storePhone != null) {
      buffer.add(utf8.encode('${receipt.storePhone}\n'));
    }
    if (receipt.taxNumber != null) {
      buffer.add(utf8.encode('Tax No: ${receipt.taxNumber}\n'));
    }
    buffer.add(utf8.encode('${'-' * width}\n'));

    buffer.add(alignLeft);
    buffer.add(utf8.encode('Invoice: ${receipt.invoiceNo}\n'));
    buffer.add(utf8.encode('Date: ${receipt.dateTimeText}\n'));
    if (receipt.cashierName != null) {
      buffer.add(utf8.encode('Cashier: ${receipt.cashierName}\n'));
    }
    if (receipt.customerName != null) {
      buffer.add(utf8.encode('Customer: ${receipt.customerName}\n'));
    }
    if (receipt.isReprint) {
      buffer.add(utf8.encode('*** REPRINT ***\n'));
    }
    if (receipt.voided) {
      buffer.add(utf8.encode('*** VOID ***\n'));
    }
    buffer.add(utf8.encode('${'-' * width}\n'));

    for (final line in receipt.lines) {
      for (final wrapped in wrap(line.name, width)) {
        buffer.add(utf8.encode('$wrapped\n'));
      }
      buffer.add(
        utf8.encode(
          '${columns('${line.quantityText} x ${line.unitPriceText}', line.totalText, width)}\n',
        ),
      );
      if (line.discountText != null) {
        buffer.add(
          utf8.encode(
            '${columns('  Discount', line.discountText!, width)}\n',
          ),
        );
      }
    }

    buffer.add(utf8.encode('${'-' * width}\n'));
    buffer.add(
      utf8.encode('${columns('Subtotal', receipt.subtotalText, width)}\n'),
    );
    if (receipt.discountText != null) {
      buffer.add(
        utf8.encode('${columns('Discount', receipt.discountText!, width)}\n'),
      );
    }
    buffer.add(
      utf8.encode('${columns('TOTAL', receipt.totalText, width)}\n'),
    );
    if (receipt.paidText != null) {
      buffer.add(
        utf8.encode('${columns('Paid', receipt.paidText!, width)}\n'),
      );
    }
    if (receipt.outstandingText != null) {
      buffer.add(
        utf8.encode(
          '${columns('Balance', receipt.outstandingText!, width)}\n',
        ),
      );
    }

    if (receipt.payments.isNotEmpty) {
      buffer.add(utf8.encode('${'-' * width}\n'));
      for (final payment in receipt.payments) {
        final label = payment.currencyCode == null
            ? payment.methodLabel
            : '${payment.methodLabel} (${payment.currencyCode})';
        buffer.add(
          utf8.encode('${columns(label, payment.amountText, width)}\n'),
        );
      }
    }

    if (receipt.footer != null) {
      buffer.add(utf8.encode('${'-' * width}\n'));
      buffer.add(alignCentre);
      for (final line in wrap(receipt.footer!, width)) {
        buffer.add(utf8.encode('$line\n'));
      }
    }

    buffer.add(alignCentre);
    buffer.add(feedAndCut);
    if (effectiveConfig.openCashDrawer) {
      buffer.add(kickCashDrawer);
    }
    return buffer.toBytes();
  }

  /// Wraps a rendered monochrome bitmap in ESC/POS raster commands.
  ///
  /// [pixels] is a row-major 1-bit-per-pixel buffer, [bytesPerRow] is its stride
  /// and [height] its height. The receipt is printed as one image, so Arabic
  /// shaping, right-to-left order and mixed Arabic and Latin text are exactly as
  /// rendered and no character-encoding support is required from the printer.
  Uint8List buildRaster({
    required Uint8List pixels,
    required int bytesPerRow,
    required int height,
    ReceiptConfig? config,
  }) {
    final effectiveConfig = config ?? const ReceiptConfig();
    final buffer = BytesBuilder();
    buffer.add(initialise);

    // GS v 0 : print raster bit image.
    final header = BytesBuilder();
    header.addByte(0x1D);
    header.addByte(0x76);
    header.addByte(0x30);
    header.addByte(0x00); // normal mode
    header.addByte(bytesPerRow & 0xFF);
    header.addByte((bytesPerRow >> 8) & 0xFF);
    header.addByte(height & 0xFF);
    header.addByte((height >> 8) & 0xFF);
    buffer.add(header.toBytes());
    buffer.add(pixels);

    buffer.add(feedAndCut);
    if (effectiveConfig.openCashDrawer) {
      buffer.add(kickCashDrawer);
    }
    return buffer.toBytes();
  }

  /// Chooses the right representation for a receipt.
  ///
  /// When [rasterRenderer] is supplied and the receipt contains Arabic, the
  /// receipt is rasterised. Otherwise plain text is used. If Arabic is present
  /// and no renderer was supplied, this throws rather than printing unreadable
  /// bytes, because a receipt the customer cannot read is worse than a clear
  /// error.
  Uint8List build(
    Receipt receipt, {
    ReceiptConfig? config,
    RasterRenderer? rasterRenderer,
  }) {
    final needsRaster = receiptContainsArabic(receipt);
    if (!needsRaster) return buildText(receipt, config: config);
    if (rasterRenderer == null) {
      throw const PrinterException(
        'This receipt contains Arabic text, but no raster renderer is '
        'available. Most thermal printers cannot print Arabic directly.',
      );
    }
    final image = rasterRenderer(receipt, (config ?? const ReceiptConfig()).paperWidth);
    return buildRaster(
      pixels: image.pixels,
      bytesPerRow: image.bytesPerRow,
      height: image.height,
      config: config,
    );
  }
}

/// A monochrome bitmap ready to be sent to a printer.
class RasterImage {
  const RasterImage({
    required this.pixels,
    required this.bytesPerRow,
    required this.height,
  });

  /// Row-major, one bit per pixel, most significant bit leftmost.
  final Uint8List pixels;

  /// Bytes per row, which is the printer's width in dots divided by eight.
  final int bytesPerRow;

  final int height;
}

/// Renders a receipt to a monochrome bitmap.
///
/// Supplied by the Flutter layer, where text can actually be drawn, so this
/// class stays free of rendering dependencies.
typedef RasterRenderer = RasterImage Function(
  Receipt receipt,
  PaperWidth paperWidth,
);
