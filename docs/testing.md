# Testing

## How to run the tests

```sh
export PATH="/opt/flutter-sdk/flutter/bin:$PATH"
flutter test                                   # everything
flutter test test/unit                         # unit tests only
flutter test test/integration                  # database integration tests
flutter test test/widget                       # widget tests
flutter test --plain-name "rolls back"         # one test by name
```

Tests run on the Dart VM with `flutter_test`. They need no device, no emulator
and no emulator image.

## Architecture of the test suite

| Layer | Directory | What it proves |
|---|---|---|
| Unit | `test/unit/` | Pure logic: money, rounding, exchange rates, quantities. No Flutter widget binding, no database. |
| Integration | `test/integration/` | Real SQLite through Drift, against an in-memory database. Schema, constraints, transactions, services. |
| Widget | `test/widget/` | The real widget tree: router, adaptive shell, providers, localisation, dashboard queries. |
| Integration (app) | `integration_test/` | Reserved for on-device end-to-end runs (Phase 10). |

### No mocks in the data path

The integration and widget tests use the **real** `AppDatabase`, the real Drift
queries and the real repository. Only the storage location is swapped: tests
override `databaseProvider` with `AppDatabase.memory()`, which is the same code
path against an in-memory SQLite file.

Nothing is stubbed to return a fixed value, so a test passing means the actual
query, the actual schema and the actual arithmetic all work together. A
hand-written fake would have hidden exactly the class of bug these tests are
meant to catch.

## What is covered

### `test/unit/rounding_test.dart` — 8 tests
`mulDivRound` exact results, half-away-from-zero for positive and negative
values, `down`/`up`/`halfDown` modes, no overflow on a large product,
`throwsArgumentError` on division by zero, `pow10`.

### `test/unit/money_test.dart` — 20 tests
`fromMajor` for 0-, 2- and 3-digit currencies; parsing of whole, fractional,
signed, comma-grouped and dot-leading values; rejection of over-precise and
malformed input; rounding on parse; formatting with a custom separator;
parse/format round trips; addition, subtraction and negation; precision
mismatch throwing; `timesRational`; `allocateEvenly` and `allocate` preserving
the total exactly; rejection of non-positive weights; comparison operators and
`hashCode`; zero/positive/negative predicates; `scale`.

### `test/unit/exchange_rate_test.dart` — 13 tests
The documented conversion direction for a 2-digit-to-2-digit pair and for a
0-digit-to-2-digit pair; `fromBase` as the inverse; the identity rate; rounding
applied once; negative-denominator normalisation; rejection of a zero numerator
or denominator; equality; decimal display; a 3-part allocation of a converted
amount preserving the total; **historical-rate immutability** — recomputing a
posted invoice with a newer rate gives a different number, which is the proof
that reports read the stored value.

### `test/unit/quantity_test.dart` — 12 tests
The documented scale of 1000; parsing whole, fractional, signed and dot-leading
values; rejection of four decimal places and of malformed input; `fromParts`;
exact addition, subtraction and negation; comparisons; `times`; display
trimming trailing zeros; parse/display round trips; `extendLineTotal` for a
fractional quantity, for a value needing rounding, and for a whole quantity.

### `test/integration/database_foundation_test.dart` — 27 tests

| Group | Tests |
|---|---|
| Schema and seeding | Schema version; one base currency with two digits; the seven units; one walk-in customer; seven expense categories; one owner user with no PIN hash; default settings present; re-opening does not duplicate rows |
| Foreign keys and constraints | `PRAGMA foreign_keys` is on; a product with a missing category is rejected; unique SKU; unique barcode across products; unique invoice number; deleting a referenced product is refused |
| Transactions and rollback | A throw after an insert leaves the table empty; a successful transaction commits |
| Integrity | `integrity_check` clean; no foreign key violations; the 27 indexes exist |
| Sequence service | Zero-padded increasing numbers; independent counters per type; **the counter rolls back with its transaction**; an unknown sequence name is rejected; formatting widths |
| Settings service | String/bool/int read and write; fallbacks for missing keys; negative stock defaults to `false`; locale defaults to `ar`; update replaces the value |
| Audit service | Newest-first ordering; payload serialisation |

### `test/widget/app_shell_test.dart` — 17 tests

| Group | Tests |
|---|---|
| Localisation | Both locales exposed; the seeded default is `ar`; English labels render; Arabic labels render; **`Directionality` is RTL for Arabic**; LTR for English |
| Adaptive shell | `NavigationRail` at 1600 px; `NavigationBar` at 420 px |
| Routing | Root route opens the dashboard; tapping a rail destination navigates; the POS route opens; a deep link to `/products/7/edit` resolves; an unknown route shows an error page instead of crashing |
| Dashboard on an empty database | Shows zeros, not sample data; the recent-transactions panel shows an empty state |
| Theme | Both themes present; `useMaterial3` is true |

### Total

```
97 tests, all passing
```

## Known gaps in test coverage

These are stated because they are real gaps, not oversights to hide:

1. **No coverage percentage is reported.** `flutter test --coverage` has not
   been run, so no figure is claimed. The suite covers the arithmetic core and
   the database foundation thoroughly; feature screens are not yet written, so
   they cannot be covered.
2. **No migration test yet.** The schema is at version 1 with nothing to migrate
   from. The first migration must ship with a test that opens a version-1
   database and upgrades it.
3. **No on-device integration test.** `integration_test/` exists but is empty.
   Without an Android device or emulator, nothing has been run against a real
   platform.
4. **No hardware tests.** Printing, camera scanning and USB HID input have no
   tests against real hardware, because no hardware is available. Their adapters
   will be tested against fakes, and that limitation will be documented rather
   than presented as hardware verification.
5. **No failure-injection tests for the sale transaction yet.** Rollback is
   proven for a generic transaction and for the sequence counter; the checkout
   transaction does not exist yet (Phase 3).
6. **No performance tests yet.** The indexes exist and search queries are
   designed for pagination, but no benchmark has been run.

## Test data policy

Tests build their own data. There is no shared fixture file, so a change to one
test cannot silently alter another. Every test starts from a fresh in-memory
database created in `setUp` and closed in `tearDown`.
