# Business Rules

These rules are mandatory. Where a rule is not yet enforced by code, this
document says so.

## 1. Money

**Never use `double` for money.** Every amount is an integer in the minor unit
of its currency (`Money` in `lib/core/money/money.dart`). A currency with two
decimal digits stores 100.25 as `10025`; a zero-digit currency stores 100 as
`100`; a three-digit currency stores 1.005 as `1005`.

Rules:

1. An amount is always paired with the precision of its currency. Adding two
   amounts of different precision throws rather than silently coercing.
2. Rounding happens at one defined point, never in the middle of a calculation.
3. Rounding mode is explicit. The default is half-away-from-zero; half-even,
   up and down are available where a specific report needs them.
4. `mulDivRound` uses a `BigInt` intermediate, so a large product cannot
   overflow before the division.

## 2. Quantities

**Never use floating point for inventory quantities.** Quantities are scaled
integers with a documented scale of 1000 (`Quantity.scale`), giving three
decimal places. A quantity of 1.5 is `1500`; 0.001 is `1`.

Fractional quantities are supported because the specification requires them for
weight and length units. A unit's `quantity_precision` records how many decimal
places are meaningful for it, which drives display, not storage — storage is
always the same scale so that arithmetic never has to reconcile two scales.

A quantity is never silently rounded. Parsing rejects input with more than three
decimal places rather than truncating it.

## 3. Exchange rates

`ExchangeRate` is an exact rational: `numerator / denominator`.

### Conversion direction

> **`toBase(amount)` multiplies an amount in the transaction currency by
> `numerator / denominator` and returns the amount in the base currency.**

The rate therefore expresses **how many base-currency minor units one
transaction-currency minor unit is worth**, and it is a function of *both*
currencies' decimal digits.

Worked example — base SAR (2 digits), transaction USD (2 digits), 1 USD = 3.75
SAR:

```
1 USD minor unit = 0.01 USD = 0.0375 SAR = 3.75 SAR minor units
rate = 15/4
toBase(Money(1000, digits: 2))   // 10.00 USD
  = 1000 * 15 / 4 = 3750         // 37.50 SAR
```

Worked example — base SAR (2 digits), transaction JPY (0 digits), 1 JPY = 0.025
SAR:

```
1 JPY minor unit = 1 JPY = 0.025 SAR = 2.5 SAR minor units
rate = 5/2
toBase(Money(1000, digits: 0))   // 1000 JPY
  = 1000 * 5 / 2 = 2500          // 25.00 SAR
```

The differing digits are why the rate cannot be stored as a plain decimal like
"3.75": the same market rate needs a different rational per currency pair.

### Historical rates

Every document stores the rate it used, as numerator and denominator, plus the
resulting base-currency amounts. Reports read the stored `base_*` columns.

> **A change to a configured exchange rate must never alter a posted document.**

This is enforced by construction: reports do not recompute. A test asserts that
recomputing a posted invoice with a newer rate gives a different number, proving
the stored value is what is actually read.

### Rounding

Rounding is applied once, at the end of a conversion. When an amount is split
across several documents, `Money.allocate` distributes the remainder so the
parts sum exactly to the original — no minor unit is created or lost.

## 4. Cost valuation — weighted average

Default method: **weighted average cost**.

```
10 units purchased at 100 each
10 units purchased at 120 each
weighted average = (10*100 + 10*120) / 20 = 110
```

Rules:

1. The average is stored in minor units in `product_stock.average_cost`.
2. The average is recomputed on each stock intake, weighted by the quantity
   added.
3. The cost used on a sale line is snapshotted into
   `sale_items.unit_cost`, so a later purchase cannot change the reported cost
   or profit of a posted invoice.
4. A stock return reverses the quantity and the value using the same snapshot,
   not today's average.

The averaging arithmetic and the snapshot columns exist and are unit-tested; the
service that performs intake and sale is Phase 2 and Phase 3 work.

## 5. Gross profit

> **Gross profit = sales revenue after discounts and returns − cost of goods
> sold.**

- Revenue is `SUM(sales.base_total)` over **posted** invoices in the period.
  `base_total` is net of both line and invoice discounts, because the discount
  is applied when the invoice is written.
- Cost of goods sold is `SUM(sales.base_cost_total)` for the same invoices,
  built from the snapshotted `sale_items.unit_cost`.
- Voided invoices are excluded. Returns reduce revenue and reduce cost of goods
  sold in proportion to the returned quantity.

## 6. Net operating profit

> **Net operating profit = gross profit − operating expenses.**

Expenses are summed from the `expenses` table for the period, using each
expense's stored `base_amount`.

### What is deliberately excluded, and why

| Item | Treatment | Reason |
|---|---|---|
| Exchange differences | **Not recognised.** No FX gain or loss is booked. | The application is single-store with no foreign-currency bank accounts or forward contracts. Recognising an unrealised gain on a historical invoice would require revaluation policy the specification does not define. Each document keeps its original rate, so nothing is lost if this is added later. |
| Taxes | **Not modelled.** No VAT, sales tax or income tax calculation exists. | The specification does not define a tax model, tax rates or a jurisdiction. Adding one would mean inventing business rules. Prices and totals are stored as entered. |
| Discounts | Included, in both revenue and profit. | Applied at invoice time and therefore already reflected in `base_total`. |
| Returns | Included. | A return reduces revenue and cost of goods sold. |
| Credit sales | Counted as **revenue**, not as collected cash. | Revenue is earned at posting. See rule 9. |

## 7. Inventory

**The ledger is the source of truth.** `inventory_movements` is append-only.
`product_stock` is a cache for fast reads and must always be reconcilable
against the sum of movements.

Movement types and their effect on stock:

| Type | Effect |
|---|---|
| `purchase` | Increase |
| `sale` | Decrease |
| `customer_return` | Increase |
| `supplier_return` | Decrease |
| `adjustment_in` | Increase |
| `adjustment_out` | Decrease |
| `damage` | Decrease |
| `opening_stock` | Increase |

Rules:

1. Every stock change writes a movement. Nothing writes stock without one.
2. Each movement records the resulting balance, so a discrepancy is
   localisable to the movement that caused it.
3. `InventoryService` is the only permitted write path. The service is Phase 2
   work; the table, the balance cache and the reconciliation query are defined
   and the schema is tested.
4. The reconciliation query compares `product_stock.quantity_scaled` against the
   signed sum of `inventory_movements.quantity_scaled` per product.

## 8. Negative stock

**Default: disabled.** A sale that would take a product below zero is rejected
with a clear message, and the whole checkout transaction rolls back.

`SettingsKeys.allowNegativeStock` exists for a shop that genuinely needs the
behaviour. It defaults to `false` and is tested to default to `false`. If it is
enabled, the check is skipped — it is a documented, deliberate relaxation, not a
silent one.

## 9. Posted records and reversal

> **Posted sales, purchases, payments, returns, inventory movements and cash
> transactions are never deleted.**

Corrections are made by adding documents:

- A voided sale keeps its rows and changes `status` to `voided`. Its inventory
  movements are reversed by compensating movements.
- A return is a new `sales_returns` document linked to the original, with its
  own items and its own inventory movements.
- A payment reversal is a new payment document with the opposite sign, not an
  edit to the original.

The database enforces part of this: foreign keys from financial rows to master
data are `restrict`, so a referenced product cannot be deleted. A test asserts
that deleting a referenced product is refused.

## 10. Cash

`cash_transactions` records **actual physical cash movement**.

| Event | Cash transaction? |
|---|---|
| Cash sale | Yes, cash in |
| Credit sale | **No** |
| Bank transfer | **No** |
| Electronic payment | **No** |
| Expense paid in cash | Yes, cash out |
| Expense paid by transfer | **No** |
| Debt collection in cash | Yes, cash in |
| Cash session opening | Recorded as the session's opening balance |

A session's expected cash is the opening balance plus the signed sum of its cash
transactions. The closing figure is compared against the counted amount and the
difference is recorded; the difference is **not** silently absorbed.

## 11. Debts

Customer receivables and supplier payables are separate ledgers:

- `customer_account_entries` — a credit sale debits the customer, a payment
  credits them. The balance is the signed sum.
- `supplier_account_entries` — a credit purchase credits the supplier, a payment
  debits them.

Rules:

1. A balance is always derived from the ledger, never stored as a mutable total.
2. **A debt payment does not create a sale or a purchase.** It creates a payment
   record and a ledger entry linked to the account.
3. A payment is linked to the account and to its financial transaction, so a
   statement can be reconstructed from either direction.

The dashboard's customer and supplier debt figures already read these ledgers
with the sign convention above.

## 12. Transaction safety

Every critical operation runs in one database transaction:

1. Validate the document.
2. Validate stock availability.
3. Calculate all totals.
4. Write the document and its items.
5. Write payment allocations.
6. Write inventory movements.
7. Update the stock balance cache.
8. Write account ledger entries where applicable.
9. Write the audit entry.

If any step throws, the entire transaction rolls back. **A document is never
saved without its corresponding inventory and payment records.**

Tests that were executed and pass:

- A transaction that throws after inserting a row leaves the table empty.
- A transaction that succeeds commits every write.
- The document-number counter rolls back with its transaction, so a failed
  operation does not burn a number.

## 13. Reporting distinctions

Reports must keep these apart, and the dashboard already does:

| Concept | Source |
|---|---|
| Revenue | `SUM(sales.base_total)` for posted invoices |
| Collected payments | `SUM(sale_payments.base_amount)` — actual money received |
| Cost of goods sold | `SUM(sales.base_cost_total)` |
| Gross profit | Revenue − cost of goods sold |
| Operating expenses | `SUM(expenses.base_amount)` |
| Net operating profit | Gross profit − operating expenses |

> **An unpaid invoice total is revenue, not collected cash.** The two are
> separate figures and are never presented as one.

## 14. Currency of record

Each document preserves:

- the currency it was transacted in,
- the exchange rate used, as numerator and denominator,
- the equivalent base-currency amount.

Balances in different currencies are never combined without conversion. Where a
total is shown across currencies, it is a **base-currency** total, and the
underlying per-currency figures remain available.
