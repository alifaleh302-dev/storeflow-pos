# Architecture

StoreFlow POS is an offline-first retail application for Android and Windows,
built with Flutter and Dart using Clean Architecture and a feature-first
directory layout.

## Layers

```
lib/
├── main.dart              entry point
├── bootstrap.dart         opens the database, then runs the app
├── app/                   application wiring: shell, router, theme, providers
├── core/                  cross-cutting primitives with no feature knowledge
├── shared/                reusable widgets and dialogs
├── features/              one folder per business module
├── infrastructure/        platform and persistence adapters
└── l10n/                  ARB sources and generated localisations
```

### Presentation

Widgets, pages, navigation and UI state. Riverpod holds state; pages read
providers and never touch the database directly. Validation messages, loading,
empty and error states are shared widgets so every screen behaves the same way.

### Domain

Entities, business rules, calculations and repository interfaces. This layer
imports nothing from Flutter, Drift, SQLite or any plugin. The exact-arithmetic
types in `core/money` are the vocabulary it uses for money and quantities, so a
domain rule can be unit-tested on the Dart VM with no database.

`features/dashboard/domain/entities/dashboard_snapshot.dart` is the clearest
example: it holds integer minor units and exposes `grossProfit` and
`netOperatingProfit` as pure arithmetic.

### Data

Drift tables, DAOs and repository implementations.
`infrastructure/database/app_database.dart` owns the schema, migrations, indexes
and seeding. Repositories translate rows into domain entities.

### Infrastructure and platform

Barcode adapters, printer adapters, encryption, filesystem access and window
management. Every hardware capability sits behind an interface so the domain and
data layers stay platform-independent, and so a platform that cannot support a
feature can report that clearly instead of failing silently.

## Dependency direction

```
presentation ──▶ domain ◀── data
                     ▲
                     │
              infrastructure
```

Inner layers never import outer layers. A sale is processed by the same domain
logic on Android and Windows; only the UI and the hardware adapters differ.

## State management

Riverpod. Providers are declared in `app/app_providers.dart` and per feature.

`databaseProvider` deliberately throws unless overridden. `bootstrap.dart`
overrides it with the real database; tests override it with
`AppDatabase.memory()`. A test that forgets the override fails loudly instead of
silently creating a second connection to the on-disk file.

Settings that must survive a restart — theme mode and locale — are
`AsyncNotifier`s backed by the `settings` table, so the UI shows the persisted
value once the read resolves.

## Navigation

GoRouter, declared entirely in `app/router.dart`. Route paths live in the
`Routes` class so navigation code and tests reference one source of truth.
Feature routes are nested under a single `ShellRoute`, which keeps the navigation
chrome visible while the inner page changes.

## Adaptive layout

`app/shell/adaptive_shell.dart` switches at 900 logical pixels:

- **At or above 900 px** — permanent `NavigationRail` (extended at 1200 px) beside
  the content.
- **Below 900 px** — `NavigationBar` with the four most-used destinations, and the
  remainder behind a "More" bottom sheet.

Feature pages then adapt their own content: the dashboard lays metric cards out
in a 1-, 2-, 3- or 4-column grid and stacks its two panels below 1000 px.

This is a genuine layout switch. The phone layout is not stretched onto the
desktop, and the desktop layout is not squeezed onto the phone.

## Localisation and direction

Arabic and English, with Arabic as the shipped default. `MaterialApp.router`
sets `locale` from a provider, and Flutter derives `Directionality` from the
locale, so Arabic lays out RTL without per-widget direction code. Layouts use
`EdgeInsetsDirectional`, `AlignmentDirectional` and `TextAlign.end` rather than
left/right equivalents.

The bundled Tajawal font covers Arabic and Latin, so a receipt or a mixed
product name renders in one consistent face.

## Database access

`infrastructure/database/app_database.dart` is the only place the schema is
defined. `core/database` holds the services that sit on top of it:

| Service | Responsibility |
|---|---|
| `SequenceService` | Gap-free document numbers, transaction-scoped |
| `SettingsService` | Typed key/value access with safe fallbacks |
| `AuditService` | Append-only audit trail |

Each service takes the database as a constructor argument rather than reaching
for a global, which is what makes them testable against an in-memory database.

## Error handling

Failures are translated before they reach the UI. A repository returns a domain
failure or throws a typed exception; pages render a user-facing message plus an
optional retry action through the shared `ErrorView`. Raw SQLite messages and
stack traces are shown only in the details line, never in place of the message.

The dashboard demonstrates the pattern: `AsyncValue.when` renders `LoadingView`,
`ErrorView` with a retry that invalidates the provider, or the data.

## Platform-specific services

Hardware capability is reached through an interface, never a direct plugin call
from a page:

```
PrinterService      → Bluetooth / USB / network adapters
BarcodeScanner      → camera (Android) / HID keyboard (Windows)
SecureStorage       → platform keystore-backed storage
```

Each adapter must report an unsupported state honestly on a platform it cannot
serve. These adapters are Phase 7 work; the interfaces are the contract.

## Extension points for postponed features

The specification postpones multiple branches, cloud sync and multi-user
permissions. The schema and layering do not prevent them:

- Every document is already keyed by its own identifier, so a `branch_id` column
  can be added in a migration.
- Financial state is derived from append-only ledgers, which is what a sync
  protocol needs to resolve conflicts.
- `users` exists with an `is_owner` flag; adding roles is a schema addition, not
  a redesign.
- `idempotency_keys` already guards critical operations against replays, which a
  sync client would rely on.
