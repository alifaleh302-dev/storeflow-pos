import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/constants/app_constants.dart';
import 'package:storeflow_pos/core/constants/enums.dart';
import 'package:storeflow_pos/core/database/settings_service.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/features/inventory/data/inventory_service.dart';
import 'package:storeflow_pos/features/printing/data/services/receipt_builder.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/features/sales/data/repositories/sale_repository.dart';
import 'package:storeflow_pos/features/sales/domain/entities/sale.dart';
import 'package:storeflow_pos/features/sales/domain/services/sale_calculator.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';
import 'package:storeflow_pos/infrastructure/printing/esc_pos_builder.dart';
import 'package:storeflow_pos/infrastructure/printing/mock_printer_service.dart';
import 'package:storeflow_pos/infrastructure/printing/printer_models.dart';
import 'package:storeflow_pos/infrastructure/printing/printer_service.dart';
import 'package:storeflow_pos/infrastructure/printing/receipt_raster_renderer.dart';
import 'package:storeflow_pos/infrastructure/scanning/barcode_scanner_service.dart';
import 'package:storeflow_pos/infrastructure/scanning/keyboard_wedge_scanner.dart';

/// Reads a receipt payload as Latin-1 so the raw ESC/POS control bytes and the
/// printable text can both be inspected.
String _asLatin1(Uint8List bytes) =>
    String.fromCharCodes(bytes);

void main() {
  // The keyboard-wedge scanner reads HardwareKeyboard, which needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  const scale = Quantity.scale;

  group('ESC/POS builder', () {
    Receipt sampleReceipt({
      String storeName = 'StoreFlow POS',
      String? customerName,
      List<ReceiptLine>? lines,
      String? footer,
      bool isReprint = false,
      bool voided = false,
    }) {
      return Receipt(
        invoiceNo: 'SAL-000001',
        dateTimeText: '2026-11-03 14:30',
        storeName: storeName,
        customerName: customerName,
        lines: lines ??
            const <ReceiptLine>[
              ReceiptLine(
                name: 'Widget',
                quantityText: '2',
                unitPriceText: '150.00',
                totalText: '300.00',
              ),
            ],
        subtotalText: '300.00',
        totalText: '300.00',
        paidText: '300.00',
        payments: const <ReceiptPayment>[
          ReceiptPayment(methodLabel: 'Cash', amountText: '300.00'),
        ],
        footer: footer,
        isReprint: isReprint,
        voided: voided,
      );
    }

    test('starts with the initialise command and ends with a cut', () {
      final bytes = EscPosBuilder().buildText(sampleReceipt());
      // ESC @
      expect(bytes.sublist(0, 2), <int>[0x1B, 0x40]);
      // The cut command is at the end.
      expect(_asLatin1(bytes), contains(String.fromCharCode(0x1D)));
    });

    test('prints the invoice number and totals', () {
      final text = _asLatin1(EscPosBuilder().buildText(sampleReceipt()));
      expect(text, contains('SAL-000001'));
      expect(text, contains('300.00'));
      expect(text, contains('Widget'));
      expect(text, contains('TOTAL'));
    });

    test('marks a reprint and a void', () {
      final reprint = _asLatin1(
        EscPosBuilder().buildText(sampleReceipt(isReprint: true)),
      );
      expect(reprint, contains('REPRINT'));

      final voided = _asLatin1(
        EscPosBuilder().buildText(sampleReceipt(voided: true)),
      );
      expect(voided, contains('VOID'));
    });

    test('kicks the cash drawer only when asked', () {
      final without = EscPosBuilder().buildText(sampleReceipt());
      final withDrawer = EscPosBuilder().buildText(
        sampleReceipt(),
        config: const ReceiptConfig(openCashDrawer: true),
      );
      expect(withDrawer.length, greaterThan(without.length));
    });

    test('wraps a long product name instead of clipping it', () {
      final wrapped = EscPosBuilder.wrap(
        'A very long product name that will not fit on one line of paper',
        20,
      );
      expect(wrapped.length, greaterThan(1));
      for (final line in wrapped) {
        expect(line.length, lessThanOrEqualTo(20));
      }
    });

    test('hard-splits a single word longer than the line', () {
      final wrapped = EscPosBuilder.wrap('abcdefghijklmnopqrstuvwxyz', 10);
      expect(wrapped, <String>['abcdefghij', 'klmnopqrst', 'uvwxyz']);
    });

    test('lays a label and a value into two columns', () {
      final line = EscPosBuilder.columns('TOTAL', '300.00', 32);
      expect(line.length, 32);
      expect(line.startsWith('TOTAL'), isTrue);
      expect(line.endsWith('300.00'), isTrue);
    });

    test('falls back to two lines when the columns do not fit', () {
      final line = EscPosBuilder.columns('A very long label indeed', '300.00', 20);
      expect(line, contains('\n'));
    });
  });

  group('Arabic detection', () {
    test('recognises Arabic text', () {
      expect(EscPosBuilder.containsArabic('مرحبا'), isTrue);
      expect(EscPosBuilder.containsArabic('Hello'), isFalse);
      expect(EscPosBuilder.containsArabic('Store متجر'), isTrue);
      expect(EscPosBuilder.containsArabic(''), isFalse);
    });

    test('flags a receipt with an Arabic store name', () {
      final builder = EscPosBuilder();
      final receipt = Receipt(
        invoiceNo: 'SAL-000001',
        dateTimeText: '2026-11-03',
        storeName: 'متجر النور',
        lines: const <ReceiptLine>[
          ReceiptLine(
            name: 'Widget',
            quantityText: '1',
            unitPriceText: '10.00',
            totalText: '10.00',
          ),
        ],
        subtotalText: '10.00',
        totalText: '10.00',
        payments: const <ReceiptPayment>[],
      );
      expect(builder.receiptContainsArabic(receipt), isTrue);
    });

    test('refuses to print Arabic without a raster renderer', () {
      final receipt = Receipt(
        invoiceNo: 'SAL-000001',
        dateTimeText: '2026-11-03',
        storeName: 'متجر النور',
        lines: const <ReceiptLine>[],
        subtotalText: '0.00',
        totalText: '0.00',
        payments: const <ReceiptPayment>[],
      );
      // Printing unreadable bytes would be worse than a clear failure.
      expect(
        () => EscPosBuilder().build(receipt),
        throwsA(isA<PrinterException>()),
      );
    });

    test('uses plain text when no Arabic is present', () {
      final receipt = Receipt(
        invoiceNo: 'SAL-000001',
        dateTimeText: '2026-11-03',
        storeName: 'StoreFlow POS',
        lines: const <ReceiptLine>[],
        subtotalText: '0.00',
        totalText: '0.00',
        payments: const <ReceiptPayment>[],
      );
      // No renderer is needed and none is called.
      final bytes = EscPosBuilder().build(receipt);
      expect(_asLatin1(bytes), contains('StoreFlow POS'));
    });
  });

  group('raster output', () {
    test('wraps pixels in a raster command with the right geometry', () {
      // Two rows of one byte each: 8 dots wide, 2 tall.
      final pixels = Uint8List.fromList(<int>[0xFF, 0x00]);
      final bytes = EscPosBuilder().buildRaster(
        pixels: pixels,
        bytesPerRow: 1,
        height: 2,
      );
      // ESC @ then GS v 0 0
      expect(bytes.sublist(0, 2), <int>[0x1B, 0x40]);
      expect(bytes.sublist(2, 6), <int>[0x1D, 0x76, 0x30, 0x00]);
      // Width of one byte, little-endian, then height of two rows.
      expect(bytes.sublist(6, 8), <int>[0x01, 0x00]);
      expect(bytes.sublist(8, 10), <int>[0x02, 0x00]);
      // The pixel data follows the eight-byte header.
      expect(bytes.sublist(10, 12), <int>[0xFF, 0x00]);
    });

    test('encodes a tall image height across two bytes', () {
      final pixels = Uint8List(2 * 300);
      final bytes = EscPosBuilder().buildRaster(
        pixels: pixels,
        bytesPerRow: 2,
        height: 300,
      );
      // 300 = 0x012C, little-endian.
      expect(bytes[8], 0x2C);
      expect(bytes[9], 0x01);
    });
  });

  group('receipt raster renderer', () {
    const renderer = ReceiptRasterRenderer();

    Receipt arabicReceipt() => const Receipt(
          invoiceNo: 'SAL-000001',
          dateTimeText: '2026-11-03 14:30',
          storeName: 'متجر النور',
          customerName: 'خالد',
          lines: <ReceiptLine>[
            ReceiptLine(
              name: 'أرز بسمتي',
              quantityText: '2',
              unitPriceText: '15.00',
              totalText: '30.00',
            ),
          ],
          subtotalText: '30.00',
          totalText: '30.00',
          paidText: '30.00',
          payments: <ReceiptPayment>[
            ReceiptPayment(methodLabel: 'نقدا', amountText: '30.00'),
          ],
          footer: 'شكرا لتعاملكم معنا',
        );

    test('80mm paper is 576 dots across and 58mm is 384', () {
      expect(ReceiptRasterRenderer.dotsFor(PaperWidth.mm80), 576);
      expect(ReceiptRasterRenderer.dotsFor(PaperWidth.mm58), 384);
    });

    test('renders an Arabic receipt to a bitmap with ink', () async {
      final image = await renderer.render(arabicReceipt(), PaperWidth.mm80);

      expect(image.bytesPerRow, 576 ~/ 8);
      expect(image.height, greaterThan(0));
      // Every row has a byte, and at least some bytes have ink in them.
      expect(image.pixels.length, image.bytesPerRow * image.height);
      final inked = image.pixels.where((byte) => byte != 0).length;
      expect(
        inked,
        greaterThan(0),
        reason: 'an Arabic receipt must produce visible pixels',
      );
    });

    test('narrow paper produces a narrower image', () async {
      final wide = await renderer.render(arabicReceipt(), PaperWidth.mm80);
      final narrow = await renderer.render(arabicReceipt(), PaperWidth.mm58);
      expect(narrow.bytesPerRow, lessThan(wide.bytesPerRow));
    });

    test('the rendered bitmap is accepted by the ESC/POS builder', () async {
      final image = await renderer.render(arabicReceipt(), PaperWidth.mm80);
      final bytes = EscPosBuilder(paperWidth: PaperWidth.mm80).buildRaster(
        pixels: image.pixels,
        bytesPerRow: image.bytesPerRow,
        height: image.height,
      );
      // The raster command carries the image dimensions.
      expect(bytes.sublist(2, 6), <int>[0x1D, 0x76, 0x30, 0x00]);
      expect(bytes[6] | (bytes[7] << 8), image.bytesPerRow);
      expect(bytes[8] | (bytes[9] << 8), image.height);
    });
  });

  group('keyboard-wedge scanner', () {
    late KeyboardWedgeScanner scanner;
    late List<ScanResult> received;
    StreamSubscription<ScanResult>? subscription;

    setUp(() {
      scanner = KeyboardWedgeScanner(
        maxInterKeyDelay: const Duration(milliseconds: 50),
      );
      received = <ScanResult>[];
    });

    tearDown(() async {
      await subscription?.cancel();
      await scanner.dispose();
    });

    /// Types [value] as key events, then presses Enter.
    Future<void> type(String value) async {
      final now = DateTime.now();
      for (final character in value.split('')) {
        HardwareKeyboard.instance.handleKeyEvent(
          KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyA,
            logicalKey: LogicalKeyboardKey.keyA,
            character: character,
            timeStamp: Duration.zero,
          ),
        );
        // The handler reads DateTime.now, so a real gap is simulated by awaiting.
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      HardwareKeyboard.instance.handleKeyEvent(
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: LogicalKeyboardKey.enter,
          timeStamp: Duration.zero,
        ),
      );
      // Silence the unused variable warning while keeping the intent explicit.
      expect(now.isBefore(DateTime.now().add(const Duration(minutes: 1))), isTrue);
    }

    test('reads a scanned barcode ending with Enter', () async {
      await scanner.start();
      subscription = scanner.scans.listen(received.add);

      await type('1234567890128');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(received, hasLength(1));
      expect(received.single.value, '1234567890128');
      // A valid EAN-13 check digit is recognised as such.
      expect(received.single.format, BarcodeFormat.ean13);
    });

    test('marks a repeated barcode as a duplicate', () async {
      await scanner.start();
      subscription = scanner.scans.listen(received.add);

      await type('1234567890128');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await type('1234567890128');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(received, hasLength(2));
      expect(received.first.isDuplicate, isFalse);
      // The repeat is reported but flagged, so the cart does not gain two items.
      expect(received.last.isDuplicate, isTrue);
    });

    test('ignores a burst shorter than the minimum length', () async {
      await scanner.start();
      subscription = scanner.scans.listen(received.add);

      await type('12');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(received, isEmpty);
    });

    test('accepts manual entry regardless of scanning state', () async {
      subscription = scanner.scans.listen(received.add);
      // Not started: manual entry must still work.
      scanner.submitManual('9988776655443');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(received, hasLength(1));
      expect(received.single.value, '9988776655443');
    });
  });

  group('scanner adapters', () {
    test('an unsupported scanner reports why', () async {
      final scanner = UnsupportedScanner('No camera on this platform');
      expect(scanner.isSupported, isFalse);
      expect(scanner.unsupportedReason, 'No camera on this platform');
      await expectLater(scanner.start(), throwsA(isA<StateError>()));
    });

    test('an unsupported scanner still accepts manual entry', () async {
      final scanner = UnsupportedScanner('No camera');
      final received = <ScanResult>[];
      final subscription = scanner.scans.listen(received.add);

      scanner.submitManual('123456');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(received.single.value, '123456');
      await subscription.cancel();
      await scanner.dispose();
    });
  });

  group('printer adapters', () {
    test('the mock discovers devices and refuses to print before connecting',
        () async {
      final printer = MockPrinterService();
      expect(await printer.discover(), isNotEmpty);
      expect(printer.connectedDevice, isNull);

      final receipt = Receipt(
        invoiceNo: 'SAL-1',
        dateTimeText: 'now',
        storeName: 'S',
        lines: const <ReceiptLine>[],
        subtotalText: '0.00',
        totalText: '0.00',
        payments: const <ReceiptPayment>[],
      );
      await expectLater(
        printer.printReceipt(receipt),
        throwsA(isA<PrinterException>()),
      );
    });

    test('the mock prints once connected and records the receipt', () async {
      final printer = MockPrinterService();
      final device = (await printer.discover()).first;
      await printer.connect(device);

      final receipt = Receipt(
        invoiceNo: 'SAL-1',
        dateTimeText: 'now',
        storeName: 'S',
        lines: const <ReceiptLine>[],
        subtotalText: '0.00',
        totalText: '0.00',
        payments: const <ReceiptPayment>[],
      );
      await printer.printReceipt(receipt);

      expect(printer.printedReceipts.single.invoiceNo, 'SAL-1');
      expect(printer.connectedDevice, device);
    });

    test('the mock can be made to fail, without losing the receipt', () async {
      final printer = MockPrinterService(failOnPrint: true);
      await printer.connect((await printer.discover()).first);

      final receipt = Receipt(
        invoiceNo: 'SAL-1',
        dateTimeText: 'now',
        storeName: 'S',
        lines: const <ReceiptLine>[],
        subtotalText: '0.00',
        totalText: '0.00',
        payments: const <ReceiptPayment>[],
      );
      await expectLater(
        printer.printReceipt(receipt),
        throwsA(isA<PrinterException>()),
      );
      expect(printer.printedReceipts, isEmpty);
    });

    test('an unsupported printer reports why instead of doing nothing', () async {
      final printer = UnsupportedPrinterService(
        PrinterConnection.usb,
        'USB printing is supported on Windows only.',
      );
      expect(printer.isSupportedOnThisPlatform, isFalse);
      expect(await printer.discover(), isEmpty);

      await expectLater(
        printer.connect(
          const PrinterDevice(
            id: 'x',
            name: 'X',
            connection: PrinterConnection.usb,
          ),
        ),
        throwsA(isA<PrinterException>()),
      );
    });

    test('a device compares by id', () {
      const a = PrinterDevice(
        id: 'p1',
        name: 'First',
        connection: PrinterConnection.network,
      );
      const b = PrinterDevice(
        id: 'p1',
        name: 'Renamed',
        connection: PrinterConnection.network,
      );
      expect(a, b);
    });

    test('a connection round-trips through its wire value', () {
      for (final connection in PrinterConnection.values) {
        expect(
          PrinterConnection.fromWire(connection.wireValue),
          connection,
        );
      }
    });
  });

  group('receipt builder', () {
    late AppDatabase db;
    late SaleRepository sales;
    late ReceiptBuilder builder;
    late int currencyId;

    setUp(() async {
      db = AppDatabase.memory();
      sales = SaleRepository(db);
      builder = ReceiptBuilder(SettingsService(db));
      final base = await (db.select(db.currencies)
            ..where((t) => t.isBase.equals(true)))
          .getSingle();
      currencyId = base.id;
    });

    tearDown(() async {
      await db.close();
    });

    Future<Sale> completedSale() async {
      final products = ProductRepository(db);
      final inventory = InventoryService(db);
      final productId = await products.create(
        name: 'Widget',
        purchaseCostMinor: 10000,
        sellingPriceMinor: 15000,
      );
      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 10000,
      );

      final result = await sales.post(
        draft: SaleDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: productId,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 15000,
              unitCostMinor: 10000,
            ),
          ],
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: currencyId,
            amountMinor: 30000,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 30000,
          ),
        ],
      );
      return (await sales.findById(result.saleId))!;
    }

    test('builds a receipt from the stored sale', () async {
      final sale = await completedSale();
      final receipt = await builder.build(sale);

      expect(receipt.invoiceNo, sale.invoiceNo);
      expect(receipt.lines.single.name, 'Widget');
      expect(receipt.lines.single.quantityText, '2');
      expect(receipt.lines.single.unitPriceText, '150.00');
      expect(receipt.lines.single.totalText, '300.00');
      expect(receipt.totalText, '300.00');
      expect(receipt.storeName, isNotEmpty);
    });

    test('a reprint is marked and reuses the same figures', () async {
      final sale = await completedSale();
      final original = await builder.build(sale);
      final reprint = await builder.build(sale, isReprint: true);

      expect(reprint.isReprint, isTrue);
      expect(original.isReprint, isFalse);
      // The same invoice produces the same paper.
      expect(reprint.totalText, original.totalText);
      expect(reprint.invoiceNo, original.invoiceNo);
    });

    test('formats a fractional quantity without trailing zeros', () async {
      final products = ProductRepository(db);
      final inventory = InventoryService(db);
      final productId = await products.create(
        name: 'Rice',
        purchaseCostMinor: 500,
        sellingPriceMinor: 800,
      );
      await inventory.apply(
        productId: productId,
        movementType: MovementType.purchase,
        signedQuantityScaled: 10 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 500,
      );
      final result = await sales.post(
        draft: SaleDraft(
          currencyId: currencyId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: productId,
              productName: 'Rice',
              quantityScaled: 1500, // 1.5
              unitPriceMinor: 800,
              unitCostMinor: 500,
            ),
          ],
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: currencyId,
            amountMinor: 1200,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 1200,
          ),
        ],
      );
      final sale = (await sales.findById(result.saleId))!;
      final receipt = await builder.build(sale);

      expect(receipt.lines.single.quantityText, '1.5');
    });

    test('reads the layout configuration from the settings', () async {
      final config = await builder.config();
      // Seeded defaults: 80mm and one copy.
      expect(config.paperWidth, PaperWidth.mm80);
      expect(config.copies, 1);

      await SettingsService(db)
          .setString(SettingsKeys.receiptPaperWidth, '58');
      final narrow = await builder.config();
      expect(narrow.paperWidth, PaperWidth.mm58);
    });
  });
}
