/// Application-wide constants that are referenced from more than one feature.
library;

/// Database schema version. Bump this and add a migration step in
/// `lib/infrastructure/database/database.dart` whenever a table changes.
const int kSchemaVersion = 1;

/// File extension for encrypted StoreFlow backups.
const String kBackupExtension = 'sfp';

/// Magic header bytes written at the start of every backup file.
const List<int> kBackupMagic = <int>[0x53, 0x46, 0x50, 0x01]; // "SFP\x01"

/// Current backup format version, checked on restore for compatibility.
const int kBackupFormatVersion = 1;

/// Store-level settings keys persisted in the `settings` table.
abstract final class SettingsKeys {
  static const String storeName = 'store_name';
  static const String storeAddress = 'store_address';
  static const String storePhone = 'store_phone';
  static const String storeTaxNumber = 'store_tax_number';
  static const String baseCurrencyId = 'base_currency_id';
  static const String locale = 'locale';
  static const String themeMode = 'theme_mode';
  static const String allowNegativeStock = 'allow_negative_stock';
  static const String receiptFooter = 'receipt_footer';
  static const String receiptPaperWidth = 'receipt_paper_width';
  static const String receiptCopies = 'receipt_copies';
  static const String defaultCustomerId = 'default_customer_id';
  static const String onboardingComplete = 'onboarding_complete';
}

/// Codes for the built-in unit rows seeded on first launch.
abstract final class UnitCodes {
  static const String piece = 'piece';
  static const String box = 'box';
  static const String kilogram = 'kilogram';
  static const String gram = 'gram';
  static const String liter = 'liter';
  static const String meter = 'meter';
  static const String package = 'package';
}
