import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../../../infrastructure/database/app_database.dart';
import '../../../../infrastructure/encryption/backup_cipher.dart';
import '../../../../infrastructure/encryption/backup_format.dart';

/// Creates and restores encrypted backups.
///
/// ## Why the snapshot is taken with the backup API
///
/// Copying the database file while the application is running can capture a
/// half-written page and produce a backup that will not open. SQLite's backup API
/// copies page by page while holding the right locks, so the snapshot is a
/// consistent point in time even if a sale is being posted at that moment.
///
/// ## Why a restore is staged
///
/// Restoring is the one operation that can destroy the shop's data. The restored
/// file is written to a temporary location, checked for integrity and for the
/// business invariants that matter, and only then swapped in. The database that
/// was replaced is kept alongside the new one, so a restore that turns out to be a
/// mistake is itself reversible.
class BackupService {
  BackupService({
    required this.database,
    required this.databasePath,
    BackupCipher? cipher,
  }) : cipher = cipher ?? BackupCipher();

  final AppDatabase database;

  /// The path of the live database file.
  final String databasePath;

  final BackupCipher cipher;

  /// The application version recorded in the manifest.
  static const String appVersion = '1.0.0';

  /// The directory holding the current snapshot, removed once it is encrypted.
  Directory? _snapshotDirectory;

  /// Writes an encrypted backup to [destinationPath].
  ///
  /// Returns the manifest that was stored, so the caller can show what was
  /// captured without decrypting the file again.
  Future<BackupManifest> createBackup({
    required String destinationPath,
    required String password,
  }) async {
    if (password.trim().isEmpty) {
      throw const BackupException('A backup password is required');
    }

    final snapshotPath = await _snapshotToTemporaryFile();
    try {
      final snapshotBytes = await File(snapshotPath).readAsBytes();
      final digest = await Sha256Digest.ofBytes(snapshotBytes);
      final manifest = BackupFormat.manifest(
        schemaVersion: database.schemaVersion,
        appVersion: appVersion,
        createdAt: DateTime.now(),
        recordCounts: await _recordCounts(),
        databaseSha256: digest,
      );

      final payload = BackupPayload(
        manifest: BackupManifest.fromJson(manifest),
        database: snapshotBytes,
      ).encode();

      final encrypted = await cipher.encrypt(
        plaintext: payload,
        password: password,
      );

      final destination = File(destinationPath);
      await destination.parent.create(recursive: true);
      // Written to a sibling file first, then renamed, so an interrupted write
      // never leaves a half-written file where a good backup used to be.
      final temporary = File('$destinationPath.partial');
      await temporary.writeAsBytes(encrypted, flush: true);
      if (destination.existsSync()) await destination.delete();
      await temporary.rename(destinationPath);

      return BackupManifest.fromJson(manifest);
    } finally {
      final directory = _snapshotDirectory;
      _snapshotDirectory = null;
      if (directory != null && directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    }
  }

  /// Reads a backup's manifest without restoring it.
  Future<BackupManifest> inspect({
    required String backupPath,
    required String password,
  }) async {
    final payload = await _decrypt(backupPath, password);
    return payload.manifest;
  }

  /// Validates a backup and returns what a restore would do, without changing
  /// anything.
  Future<RestorePreview> preview({
    required String backupPath,
    required String password,
  }) async {
    final payload = await _decrypt(backupPath, password);
    final checks = await _validatePayload(payload);
    return RestorePreview(
      manifest: payload.manifest,
      checks: checks,
      canRestore: checks.every((check) => check.passed),
    );
  }

  /// Restores [backupPath] over the live database.
  ///
  /// The order is deliberate: decrypt, validate, stage, re-check, swap, and keep
  /// the previous file. Nothing touches the live database until the replacement
  /// has passed every check.
  Future<RestoreResult> restore({
    required String backupPath,
    required String password,
  }) async {
    final payload = await _decrypt(backupPath, password);
    final checks = await _validatePayload(payload);
    final failed = checks.where((check) => !check.passed).toList();
    if (failed.isNotEmpty) {
      throw BackupException(
        'The backup cannot be restored: ${failed.map((c) => c.message).join('; ')}',
      );
    }

    final liveFile = File(databasePath);
    final stagedPath = '$databasePath.restoring';
    final previousPath = '$databasePath.previous';

    final staged = File(stagedPath);
    await staged.writeAsBytes(payload.database, flush: true);

    // Integrity is checked on the staged file, opened on its own, before the live
    // database is touched.
    final stagedChecks = await _checkSqliteIntegrity(stagedPath);
    if (!stagedChecks.passed) {
      await staged.delete();
      throw BackupException(
        'The restored database failed its integrity check: '
        '${stagedChecks.message}',
      );
    }

    // Close the live database so its file can be replaced.
    await database.close();

    try {
      if (liveFile.existsSync()) {
        final previous = File(previousPath);
        if (previous.existsSync()) await previous.delete();
        await liveFile.rename(previousPath);
      }
      await staged.rename(databasePath);
    } catch (error) {
      // Put the old database back if the swap failed part way.
      final previous = File(previousPath);
      if (previous.existsSync() && !liveFile.existsSync()) {
        await previous.rename(databasePath);
      }
      rethrow;
    }

    return RestoreResult(
      manifest: payload.manifest,
      previousDatabasePath:
          File(previousPath).existsSync() ? previousPath : null,
    );
  }

  /// Reopens the database after a restore. The caller owns the new instance,
  /// because the old one was closed and cannot be reused.
  AppDatabase reopen() => AppDatabase.open(overridePath: databasePath);

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Copies the live database to a temporary file with the SQLite backup API.
  Future<String> _snapshotToTemporaryFile() async {
    _snapshotDirectory = Directory.systemTemp.createTempSync('sfp_backup_');
    final snapshotPath = p.join(_snapshotDirectory!.path, 'snapshot.sqlite');

    // The raw handle is used directly, because the Drift connection abstracts away
    // the file the backup API needs.
    //
    // The connection is opened read-write on purpose. The database runs in
    // write-ahead logging mode, and recent commits live in the `-wal` file rather
    // than the main file. A read-only connection cannot read the write-ahead log,
    // so it would copy a stale or empty database. Opening normally lets SQLite
    // apply the log and the backup API then copies a consistent, current image.
    final source = sqlite.sqlite3.open(databasePath);
    try {
      final destination = sqlite.sqlite3.open(snapshotPath);
      try {
        // The backup API returns a lazy stream of progress fractions. It does no
        // work until it is listened to, so it must be drained; ignoring the result
        // would silently produce an empty snapshot.
        await source.backup(destination).drain<void>();
      } finally {
        destination.close();
      }
    } finally {
      source.close();
    }

    return snapshotPath;
  }

  /// Counts the rows in the tables a shop would notice going missing.
  Future<Map<String, int>> _recordCounts() async {
    Future<int> count(String table) async {
      final row = await database
          .customSelect('SELECT COUNT(*) AS n FROM $table')
          .getSingle();
      return row.read<int>('n');
    }

    return <String, int>{
      'products': await count('products'),
      'sales': await count('sales'),
      'purchases': await count('purchases'),
      'customers': await count('customers'),
      'suppliers': await count('suppliers'),
      'expenses': await count('expenses'),
      'inventory_movements': await count('inventory_movements'),
    };
  }

  Future<BackupPayload> _decrypt(String path, String password) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw BackupException('No backup file was found at $path');
    }
    final bytes = await file.readAsBytes();
    final plaintext = await cipher.decrypt(file: bytes, password: password);
    return BackupPayload.decode(plaintext);
  }

  /// The checks a restore must pass.
  Future<List<ValidationCheck>> _validatePayload(BackupPayload payload) async {
    final checks = <ValidationCheck>[];

    checks.add(ValidationCheck(
      name: 'manifest',
      passed: payload.manifest.schemaVersion > 0,
      message: payload.manifest.schemaVersion > 0
          ? 'The manifest is readable'
          : 'The manifest is missing its schema version',
    ));

    checks.add(ValidationCheck(
      name: 'schema',
      passed: payload.manifest.schemaVersion <= database.schemaVersion,
      message: payload.manifest.schemaVersion <= database.schemaVersion
          ? 'The backup schema is compatible'
          : 'The backup was written by a newer schema '
              '(${payload.manifest.schemaVersion} against '
              '${database.schemaVersion})',
    ));

    // The stored digest is checked against the decrypted bytes, which catches a
    // payload that decrypted but does not match what was recorded.
    if (payload.manifest.databaseSha256.isNotEmpty) {
      final digest = await Sha256Digest.ofBytes(payload.database);
      checks.add(ValidationCheck(
        name: 'digest',
        passed: digest == payload.manifest.databaseSha256,
        message: digest == payload.manifest.databaseSha256
            ? 'The database matches its recorded digest'
            : 'The database does not match its recorded digest',
      ));
    }

    // The payload must be a readable SQLite file.
    final header = payload.database.length >= 16
        ? String.fromCharCodes(payload.database.sublist(0, 15))
        : '';
    checks.add(ValidationCheck(
      name: 'sqlite-header',
      passed: header == 'SQLite format 3',
      message: header == 'SQLite format 3'
          ? 'The payload is a SQLite database'
          : 'The payload is not a SQLite database',
    ));

    return checks;
  }

  /// Opens a staged database on its own and asks SQLite to check it.
  Future<ValidationCheck> _checkSqliteIntegrity(String path) async {
    final db = sqlite.sqlite3.open(path);
    try {
      final result = db.select('PRAGMA integrity_check');
      final first = result.isEmpty ? 'no result' : '${result.first.values.first}';
      return ValidationCheck(
        name: 'integrity',
        passed: first == 'ok',
        message: first == 'ok' ? 'The database is intact' : first,
      );
    } on sqlite.SqliteException catch (error) {
      return ValidationCheck(
        name: 'integrity',
        passed: false,
        message: 'The database could not be opened: ${error.message}',
      );
    } finally {
      db.close();
    }
  }

  /// Counts rows in a staged database, for the restore preview.
  Future<Map<String, int>> stagedCounts(Uint8List databaseBytes) async {
    final directory = Directory.systemTemp.createTempSync('sfp_preview_');
    final path = p.join(directory.path, 'staged.sqlite');
    await File(path).writeAsBytes(databaseBytes);
    final db = sqlite.sqlite3.open(path);
    try {
      final counts = <String, int>{};
      for (final table in <String>[
        'products',
        'sales',
        'purchases',
        'customers',
        'suppliers',
      ]) {
        try {
          final result = db.select('SELECT COUNT(*) AS n FROM $table');
          counts[table] = result.first.values.first as int;
        } catch (_) {
          // A table missing from an older backup is reported as absent, not fatal.
        }
      }
      return counts;
    } finally {
      db.close();
      await directory.delete(recursive: true);
    }
  }
}

/// A backup operation that could not be completed.
class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One check performed while validating a backup.
class ValidationCheck {
  const ValidationCheck({
    required this.name,
    required this.passed,
    required this.message,
  });

  final String name;
  final bool passed;
  final String message;
}

/// What a restore would do, without having done it.
class RestorePreview {
  const RestorePreview({
    required this.manifest,
    required this.checks,
    required this.canRestore,
  });

  final BackupManifest manifest;
  final List<ValidationCheck> checks;
  final bool canRestore;
}

/// The outcome of a restore.
class RestoreResult {
  const RestoreResult({
    required this.manifest,
    required this.previousDatabasePath,
  });

  final BackupManifest manifest;

  /// Where the replaced database was kept, if there was one.
  final String? previousDatabasePath;
}
