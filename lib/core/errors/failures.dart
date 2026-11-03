/// Domain-level failure types.
///
/// The domain layer must not depend on Flutter, SQLite or platform plugins, so
/// it reports problems with these types instead of throwing driver exceptions.
/// Data and infrastructure layers translate their own errors into these.
sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.details});

  /// Human-readable, already-localised-by-the-caller key or message.
  final String message;

  /// Optional machine-readable context (ids, codes) for diagnostics.
  final Map<String, Object?>? details;

  /// Stable identifier used by the localisation layer to render a message.
  String get code;

  @override
  String toString() => '$runtimeType($code): $message';
}

/// Input failed validation before touching the database.
class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {this.field, super.details});

  /// The offending form field, when the failure is field-specific.
  final String? field;

  @override
  String get code => 'validation';
}

/// A requested entity does not exist.
class NotFoundFailure extends AppFailure {
  const NotFoundFailure(super.message, {super.details});

  @override
  String get code => 'not_found';
}

/// An operation would violate a business rule (stock, balances, status...).
class BusinessRuleFailure extends AppFailure {
  const BusinessRuleFailure(super.message, {super.details});

  @override
  String get code => 'business_rule';
}

/// Insufficient stock for the requested quantity.
class InsufficientStockFailure extends BusinessRuleFailure {
  const InsufficientStockFailure({
    required this.productName,
    required this.availableScaled,
    required this.requestedScaled,
  }) : super('insufficient_stock');

  final String productName;
  final int availableScaled;
  final int requestedScaled;

  @override
  String get code => 'insufficient_stock';
}

/// A database or storage operation failed.
class StorageFailure extends AppFailure {
  const StorageFailure(super.message, {super.details, this.cause});

  final Object? cause;

  @override
  String get code => 'storage';
}

/// A hardware adapter (printer, scanner) failed.
class HardwareFailure extends AppFailure {
  const HardwareFailure(super.message, {super.details, this.unsupported = false});

  /// True when the platform genuinely cannot provide the capability, so the UI
  /// should show an "unsupported" state rather than a retry prompt.
  final bool unsupported;

  @override
  String get code => unsupported ? 'hardware_unsupported' : 'hardware_error';
}

/// Backup or restore failed (bad password, corrupt archive, incompatible data).
class BackupFailure extends AppFailure {
  const BackupFailure(super.message, {super.details});

  @override
  String get code => 'backup';
}

/// Authentication failed.
class AuthFailure extends AppFailure {
  const AuthFailure(super.message, {super.details});

  @override
  String get code => 'auth';
}
