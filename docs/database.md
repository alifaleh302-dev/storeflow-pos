# Database

SQLite through Drift. Schema version 1, defined in
`lib/infrastructure/database/tables.dart`, assembled in
`lib/infrastructure/database/app_database.dart`.

## Connection settings

Applied on every connection, before any user query runs:

```sql
PRAGMA foreign_keys = ON;    -- off by default in SQLite; all our FK rules depend on it
PRAGMA journal_mode = WAL;   -- readers do not block a checkout writing
PRAGMA synchronous = NORMAL; -- durable across application crashes under WAL
```

`AppDatabase.checkIntegrity()` and `checkForeignKeys()` wrap
`PRAGMA integrity_check` and `PRAGMA foreign_key_check` for the restore flow.

## Storage conventions

### Money

Every monetary amount is an **integer in minor units** of a specific currency.
`100.25` in a two-digit currency is `10025`. The currency's precision lives in
`currencies.decimal_digits`, so zero-digit and three-digit currencies work.

A document stores both:

- the amount in its **transaction currency** (`amount`, `total`), and
- the equivalent in the **base currency** (`base_amount`, `base_total`),

plus the rate used, as an exact rational pair
(`exchange_rate_numerator`, `exchange_rate_denominator`).

Reports read the `base_*` columns. They never recompute with today's rate, so
changing a configured rate cannot rewrite history. See `business_rules.md` for
the conversion direction.

### Quantities

Inventory quantities are **scaled integers** with a documented scale of 1000
(`Quantity.scale`), giving three decimal places. A quantity of `1.5` is `1500`.

### Timestamps

Stored as UTC ISO-8601 text, converted to local time only for display. The
column name says so: `created_at`, `opened_at`, `closed_at`, `updated_at`.
Text was chosen over a numeric epoch so a database dump is readable and
comparable with string operators in queries.

### Soft deletion

Posted financial and inventory rows are never deleted. Master data is archived
with `is_active = 0`. Foreign keys from financial rows to master data use
`KeyAction.restrict`, so the database itself refuses to delete a product that
appears on an invoice.

## Tables

37 tables. All 35 required by the specification, plus two.

### Products
`categories`, `units`, `products`, `product_barcodes`, `product_prices`,
`product_stock`

`product_stock` holds one row per product: `quantity_scaled` and
`average_cost` (minor units, weighted average). It is a cache for fast reads;
`inventory_movements` is the source of truth, and the two are reconcilable.

`product_barcodes` allows several barcodes per product, with a unique index on
the barcode itself so a scan resolves to exactly one product.

### Sales
`sales`, `sale_items`, `sale_payments`, `sales_returns`, `sales_return_items`

`sale_items` stores `product_name_snapshot`, `unit_price` and `unit_cost` as
they were at posting time, so a later price or cost change cannot alter a posted
invoice or its reported profit.

`sales.status` is one of `draft`, `posted`, `voided`. There is no delete path
for a posted invoice; a void or a return is a new document.

### Purchases
`suppliers`, `purchases`, `purchase_items`, `purchase_payments`,
`purchase_returns`, `purchase_return_items`

### Inventory
`inventory_movements`, `stock_adjustments`, `stock_adjustment_items`

`inventory_movements` is append-only and records, for each change:
`movement_type`, signed `quantity_scaled`, `balance_after_scaled`, and the
`reference_type`/`reference_id` of the document that caused it. Recording the
balance after each movement makes a ledger discrepancy localisable to the
movement that introduced it.

### Accounts
`customers`, `customer_payments`, `supplier_payments`,
`customer_account_entries`, `supplier_account_entries`

The account entry tables are append-only ledgers. A customer's balance is the
signed sum of their entries, so it can always be reconstructed and audited
rather than trusted from a stored total.

### Financial
`currencies`, `exchange_rates`, `expenses`, `expense_categories`,
`cash_sessions`, `cash_transactions`

`exchange_rates` keeps history keyed by `effective_from`, so a rate change adds
a row instead of overwriting the previous rate.

`cash_transactions` records actual cash movement only. A credit sale creates no
cash transaction; a bank transfer creates no cash transaction.

### Application
`users`, `settings`, `audit_logs`, `backup_history`

### Additional tables (documented per the specification's allowance)

| Table | Why it exists |
|---|---|
| `document_sequences` | Human-readable document numbers must survive a restart and must not collide. A counter row per document type, incremented inside the caller's transaction, gives gap-free numbering that rolls back with the transaction. Deriving the next number with `MAX(invoice_no)` would be racy and would reissue numbers after a void. |
| `idempotency_keys` | Guards critical operations against a double tap or a retried submission. A sale or payment submission records its key in the same transaction; a repeat finds the key and returns the original result instead of posting twice. |

## Indexes

27 named indexes beyond the primary keys, unique constraints and foreign keys
Drift generates. They cover the columns the application actually filters and
sorts on:

| Area | Examples |
|---|---|
| Product search | `idx_products_name`, `idx_products_category`, `idx_products_active`, `idx_barcodes_product` |
| Sales | `idx_sales_created`, `idx_sales_customer`, `idx_sales_status`, `idx_sale_items_product` |
| Purchases | `idx_purchases_created`, `idx_purchases_supplier`, `idx_purchases_status` |
| Inventory | `idx_movements_product`, `idx_movements_created`, `idx_movements_reference` |
| Accounts | `idx_customer_entries_customer`, `idx_supplier_entries_supplier` |
| Reporting | `idx_expenses_created`, `idx_cash_transactions_created`, `idx_exchange_rates_currency` |

Date columns are indexed because every report filters on a range.

## Migrations

`schemaVersion` is `kSchemaVersion` in `core/constants/app_constants.dart`,
currently `1`. The `MigrationStrategy` has three hooks:

- `onCreate` — creates all tables, adds the custom indexes, seeds defaults.
- `onUpgrade` — calls `_migrate`, which is where each future version appends its
  own step, then re-adds the custom indexes.
- `beforeOpen` — enables foreign keys and WAL, and seeds defaults on a
  freshly-created database.

Rules for future migrations:

1. Never drop or rewrite a posted financial row.
2. Add a column with a default, or add a new table, rather than mutating
   existing data in place.
3. Bump `kSchemaVersion` and add the matching `if (from < N)` branch.
4. Add a test that opens a database at version `N-1` and migrates it.

## Seeding

`_seedDefaults` runs inside a transaction and is idempotent — it checks for an
existing row before inserting. It creates:

- the base currency (SAR, two decimal digits, `is_base = 1`),
- seven units (piece, box, kilogram, gram, liter, meter, package) with their
  quantity precision,
- one walk-in customer (`is_walk_in = 1`),
- seven expense categories,
- one owner user, with no PIN hash set until the owner creates one,
- default settings: store name, locale (`ar`), theme mode, negative-stock policy
  (`false`), receipt width and copies, receipt footer.

A test asserts that opening an already-seeded database does not duplicate any of
these rows.

## Deletion policy

| Row kind | Policy |
|---|---|
| Posted sale, purchase, payment, return, movement, cash transaction | Never deleted. Voided or reversed with a new document. |
| Master data referenced by a posted document | Archived (`is_active = 0`); the foreign key refuses deletion. |
| Stock adjustment items | `cascade` from their parent adjustment, which may only be deleted while still `draft`. |
| Sequence counters, settings, idempotency keys | Operational rows, freely rewritten. |
