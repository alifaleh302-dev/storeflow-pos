import 'package:flutter_test/flutter_test.dart';
import 'package:storeflow_pos/core/constants/enums.dart';
import 'package:storeflow_pos/core/errors/failures.dart';
import 'package:storeflow_pos/core/money/exchange_rate.dart';
import 'package:storeflow_pos/core/money/money.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/features/currencies/data/repositories/currency_repository.dart';
import 'package:storeflow_pos/features/customers/data/repositories/customer_repository.dart';
import 'package:storeflow_pos/features/inventory/data/inventory_service.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/features/sales/data/repositories/sale_repository.dart';
import 'package:storeflow_pos/features/sales/domain/entities/sale.dart';
import 'package:storeflow_pos/features/sales/domain/services/sale_calculator.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';

void main() {
  late AppDatabase db;
  late CurrencyRepository currencies;
  late ProductRepository products;
  late InventoryService inventory;
  late SaleRepository sales;
  late CustomerRepository customers;

  const scale = Quantity.scale;
  late int baseId;
  late int usdId;

  setUp(() async {
    db = AppDatabase.memory();
    currencies = CurrencyRepository(db);
    products = ProductRepository(db);
    inventory = InventoryService(db);
    sales = SaleRepository(db);
    customers = CustomerRepository(db);

    baseId = (await currencies.baseCurrency()).id;
    usdId = await currencies.addCurrency(code: 'usd', name: 'US Dollar');
  });

  tearDown(() async {
    await db.close();
  });

  group('currency management', () {
    test('the seeded currency is the base and uses the identity rate', () async {
      final base = await currencies.baseCurrency();
      expect(base.isBase, isTrue);
      expect(base.code, 'SAR');
    });

    test('uppercases the code and rejects a duplicate', () async {
      final eur = await currencies.findByCode('USD');
      expect(eur!.code, 'USD');

      await expectLater(
        currencies.addCurrency(code: 'usd', name: 'Another Dollar'),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('rejects a short code, a blank name and bad precision', () async {
      await expectLater(
        currencies.addCurrency(code: 'X', name: 'Too short'),
        throwsA(isA<ValidationFailure>()),
      );
      await expectLater(
        currencies.addCurrency(code: 'GBP', name: '   '),
        throwsA(isA<ValidationFailure>()),
      );
      await expectLater(
        currencies.addCurrency(code: 'GBP', name: 'Pound', decimalDigits: 9),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('lists active currencies with the base first', () async {
      final list = await currencies.active();
      expect(list.length, greaterThanOrEqualTo(2));
      expect(list.first.currency.isBase, isTrue);
    });

    test('refuses to deactivate the base currency', () async {
      await expectLater(
        currencies.updateCurrency(baseId, isActive: false),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('renames a currency without changing its precision', () async {
      await currencies.updateCurrency(usdId, name: 'US Dollar (cash)');
      final updated = await currencies.findById(usdId);
      expect(updated!.name, 'US Dollar (cash)');
      // The precision is what every stored minor unit depends on, so it is fixed.
      expect(updated.decimalDigits, 2);
    });
  });

  group('exchange rates', () {
    test('the base currency rejects a configured rate', () async {
      await expectLater(
        currencies.setRate(currencyId: baseId, numerator: 2, denominator: 1),
        throwsA(isA<ValidationFailure>()),
      );
    });

    test('rejects a zero denominator', () async {
      await expectLater(
        currencies.setRate(currencyId: usdId, numerator: 1, denominator: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('resolves the most recent rate at or before a moment', () async {
      await currencies.setRate(
        currencyId: usdId,
        numerator: 375,
        denominator: 100,
        effectiveFrom: DateTime.utc(2026, 1, 1),
      );
      await currencies.setRate(
        currencyId: usdId,
        numerator: 400,
        denominator: 100,
        effectiveFrom: DateTime.utc(2026, 6, 1),
      );

      final before = await currencies.rateAt(usdId, DateTime.utc(2026, 3, 1));
      expect(before!.numerator, 375);

      final after = await currencies.rateAt(usdId, DateTime.utc(2026, 7, 1));
      expect(after!.numerator, 400);
    });

    test('keeps every historical rate', () async {
      await currencies.setRate(
        currencyId: usdId,
        numerator: 375,
        denominator: 100,
        effectiveFrom: DateTime.utc(2026, 1, 1),
      );
      await currencies.setRate(
        currencyId: usdId,
        numerator: 400,
        denominator: 100,
        effectiveFrom: DateTime.utc(2026, 6, 1),
      );

      final history = await currencies.rateHistory(usdId);
      expect(history, hasLength(2));
      // Newest first, and the older rate is still there.
      expect(history.first.numerator, 400);
      expect(history.last.numerator, 375);
    });

    test('does not use a rate before it takes effect', () async {
      await currencies.setRate(
        currencyId: usdId,
        numerator: 400,
        denominator: 100,
        effectiveFrom: DateTime.utc(2030, 1, 1),
      );
      final past = await currencies.rateAt(usdId, DateTime.utc(2026, 1, 1));
      expect(past, isNull);
    });

    test('reports no rate rather than assuming one', () async {
      expect(await currencies.currentRate(usdId), isNull);
      final list = await currencies.active();
      final usd = list.firstWhere((c) => c.currency.id == usdId);
      // With no rate configured the identity is used, which is the only safe
      // default: it cannot silently inflate or deflate an amount.
      expect(usd.rate, isNull);
      expect(usd.effectiveRate.isIdentity, isTrue);
    });
  });

  group('conversion arithmetic', () {
    test('converts with a single rounding at the end', () {
      final rate = ExchangeRate(numerator: 375, denominator: 100);
      final converted = rate.toBase(Money(1000, decimalDigits: 2));
      // 10.00 USD at 3.75 is 37.50.
      expect(converted.minorUnits, 3750);
    });

    test('converts back with the inverse rate', () {
      // The inverse of 375/100 is 100/375.
      final inverse = ExchangeRate(numerator: 100, denominator: 375);
      expect(inverse.toBase(Money(3750, decimalDigits: 2)).minorUnits, 1000);
    });

    test('rounds a conversion that does not divide evenly', () {
      // 1 USD = 3.333 SAR, so 3.00 USD = 9.999 -> 10.00 with half-up rounding.
      final rate = ExchangeRate(numerator: 3333, denominator: 1000);
      expect(rate.toBase(Money(300, decimalDigits: 2)).minorUnits, 1000);
    });

    test('handles a zero-decimal currency exactly', () {
      // A currency with no minor units, such as the Japanese yen. The rate is
      // expressed in minor units on both sides, so a zero-decimal transaction
      // currency needs no extra scaling: 1 yen is 0.0375 SAR, which is 3.75 base
      // minor units, giving the same 375/100 rate a two-decimal currency would
      // use.
      final rate = ExchangeRate(numerator: 375, denominator: 100);
      // 1000 yen at 0.0375 SAR per yen is 37.50 SAR = 3750 minor units.
      expect(rate.toBase(Money(1000, decimalDigits: 0)).minorUnits, 3750);
    });

    test('handles a three-decimal currency exactly', () {
      final rate = ExchangeRate(numerator: 3, denominator: 1000);
      // 12345 (12.345) at 0.003 is 37.035 -> 37 minor units.
      expect(rate.toBase(Money(12345, decimalDigits: 3)).minorUnits, 37);
    });

    test('normalises a negative denominator', () {
      final rate = ExchangeRate(numerator: 375, denominator: -100);
      expect(rate.numerator, -375);
      expect(rate.denominator, 100);
    });

    test('rejects a zero numerator or denominator', () {
      expect(
        () => ExchangeRate(numerator: 0, denominator: 1),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ExchangeRate(numerator: 1, denominator: 0),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('a sale in a foreign currency', () {
    /// Stocks a product priced at 10.00 in the transaction currency.
    Future<int> stocked() async {
      final id = await products.create(
        name: 'Widget',
        purchaseCostMinor: 10000,
        sellingPriceMinor: 1000,
      );
      await inventory.apply(
        productId: id,
        movementType: MovementType.purchase,
        signedQuantityScaled: 20 * scale,
        referenceType: ReferenceType.purchase,
        allowNegativeStock: false,
        unitCost: 10000,
      );
      return id;
    }

    test('stores the rate and the base total', () async {
      final id = await stocked();
      final result = await sales.post(
        draft: SaleDraft(
          currencyId: usdId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 1000,
              unitCostMinor: 10000,
            ),
          ],
          exchangeRateNumerator: 375,
          exchangeRateDenominator: 100,
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: usdId,
            amountMinor: 2000,
            exchangeRateNumerator: 375,
            exchangeRateDenominator: 100,
            baseAmountMinor: 7500,
          ),
        ],
      );

      final sale = await sales.findById(result.saleId);
      expect(sale!.currencyId, usdId);
      expect(sale.currencyCode, 'USD');
      expect(sale.totalMinor, 2000);
      expect(sale.baseTotalMinor, 7500);
    });

    test('a later rate change does not alter the stored invoice', () async {
      final id = await stocked();
      final result = await sales.post(
        draft: SaleDraft(
          currencyId: usdId,
          currencyDecimalDigits: 2,
          lines: <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 1000,
              unitCostMinor: 10000,
            ),
          ],
          exchangeRateNumerator: 375,
          exchangeRateDenominator: 100,
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: usdId,
            amountMinor: 2000,
            exchangeRateNumerator: 375,
            exchangeRateDenominator: 100,
            baseAmountMinor: 7500,
          ),
        ],
      );

      await currencies.setRate(
        currencyId: usdId,
        numerator: 500,
        denominator: 100,
      );

      final sale = await sales.findById(result.saleId);
      expect(sale!.baseTotalMinor, 7500);
      expect(sale.exchangeRateNumerator, 375);
    });

    test('a mixed-currency payment records each currency separately', () async {
      final id = await stocked();
      final customerId = await customers.create(name: 'Buyer');

      final result = await sales.post(
        draft: SaleDraft(
          currencyId: baseId,
          currencyDecimalDigits: 2,
          customerId: customerId,
          lines: <SaleLine>[
            SaleLine(
              productId: id,
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
            currencyId: baseId,
            amountMinor: 24997,
            exchangeRateNumerator: 1,
            exchangeRateDenominator: 1,
            baseAmountMinor: 24997,
          ),
          PaymentAllocation(
            paymentMethod: PaymentMethod.cash,
            currencyId: usdId,
            amountMinor: 1334,
            exchangeRateNumerator: 375,
            exchangeRateDenominator: 100,
            baseAmountMinor: 5003,
          ),
        ],
      );

      final sale = await sales.findById(result.saleId);
      expect(sale!.payments, hasLength(2));
      expect(sale.basePaidAmountMinor, 30000);
      // Each tender keeps its own currency and the rate it was taken at.
      expect(sale.payments.first.currencyId, baseId);
      expect(sale.payments.last.currencyId, usdId);
      expect(sale.payments.last.exchangeRateNumerator, 375);
    });

    test('a foreign-currency credit sale raises the debt in base', () async {
      final id = await stocked();
      final customerId = await customers.create(name: 'Buyer');

      await sales.post(
        draft: SaleDraft(
          currencyId: usdId,
          currencyDecimalDigits: 2,
          customerId: customerId,
          lines: <SaleLine>[
            SaleLine(
              productId: id,
              productName: 'Widget',
              quantityScaled: 2 * scale,
              unitPriceMinor: 1000,
              unitCostMinor: 10000,
            ),
          ],
          exchangeRateNumerator: 375,
          exchangeRateDenominator: 100,
        ),
        payments: <PaymentAllocation>[
          PaymentAllocation(
            paymentMethod: PaymentMethod.credit,
            currencyId: usdId,
            amountMinor: 2000,
            exchangeRateNumerator: 375,
            exchangeRateDenominator: 100,
            baseAmountMinor: 7500,
          ),
        ],
      );

      // 20.00 USD of debt is 75.00 of base-currency debt.
      expect(await customers.balanceOf(customerId), 7500);
    });
  });
}
