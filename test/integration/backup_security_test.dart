import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:storeflow_pos/core/constants/enums.dart';
import 'package:storeflow_pos/core/database/audit_service.dart';
import 'package:storeflow_pos/core/money/quantity.dart';
import 'package:storeflow_pos/features/authentication/data/services/auth_service.dart';
import 'package:storeflow_pos/features/backup/data/services/backup_service.dart';
import 'package:storeflow_pos/features/inventory/data/inventory_service.dart';
import 'package:storeflow_pos/features/products/data/repositories/product_repository.dart';
import 'package:storeflow_pos/features/sales/data/repositories/sale_repository.dart';
import 'package:storeflow_pos/features/sales/domain/entities/sale.dart';
import 'package:storeflow_pos/features/sales/domain/services/sale_calculator.dart';
import 'package:storeflow_pos/infrastructure/database/app_database.dart';
import 'package:storeflow_pos/infrastructure/encryption/backup_cipher.dart';
import 'package:storeflow_pos/infrastructure/encryption/backup_format.dart';

void main() {
  const scale = Quantity.scale;

  // Argon2id at its production cost takes a noticeable moment, which is the point.
  // These parameters are the same algorithm with less work, so the real code path
  // runs without making the suite slow. The production cost is asserted separately.
  BackupCipher fastCipher() => BackupCipher(
        argon2MemoryKb: 256,
        argon2Iterations: 1,
        argon2Parallelism: 1,
      );

  group('backup format', () {
    test('the header carries the magic, version, salt and nonce', () {
      final salt = List<int>.generate(BackupFormat.saltLength, (i) => i);
      final nonce = List<int>.generate(BackupFormat.nonceLength, (i) => i + 100);
      final header = BackupFormat.encodeHeader(salt: salt, nonce: nonce);

      expect(header.sublist(0, 4), BackupFormat.magic);
      expect(header[4] | (header[5] << 8), BackupFormat.currentVersion);
      expect(
        header.sublist(6, 6 + BackupFormat.saltLength),
        salt,
      );
      expect(
        header.sublist(6 + BackupFormat.saltLength),
        nonce,
      );
      expect(header.length, BackupFormat.headerLength);
    });

    test('rejects a salt of the wrong size', () {
      expect(
        () => BackupFormat.encodeHeader(salt: <int>[1, 2, 3], nonce: List.filled(12, 0)),
        throwsArgumentError,
      );
    });

    test('a parsed header round-trips', () {
      final salt = List<int>.generate(BackupFormat.saltLength, (i) => i);
      final nonce = List<int>.generate(BackupFormat.nonceLength, (i) => i);
      final header = BackupFormat.encodeHeader(salt: salt, nonce: nonce);
      final file = Uint8List.fromList(<int>[...header, 1, 2, 3]);

      final parsed = BackupFormat.parseHeader(file);
      expect(parsed.salt, salt);
      expect(parsed.nonce, nonce);
      expect(parsed.ciphertext, <int>[1, 2, 3]);
    });

    test('rejects a file that is not a backup', () {
      final file = Uint8List.fromList(List<int>.filled(60, 7));
      expect(
        () => BackupFormat.parseHeader(file),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('rejects a file that is too short to hold a header', () {
      final file = Uint8List.fromList(<int>[0x53, 0x46]);
      expect(
        () => BackupFormat.parseHeader(file),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('rejects a header from a different format version', () {
      final salt = List<int>.filled(BackupFormat.saltLength, 0);
      final nonce = List<int>.filled(BackupFormat.nonceLength, 0);
      final header = BackupFormat.encodeHeader(salt: salt, nonce: nonce, version: 99);
      final file = Uint8List.fromList(<int>[...header, 1, 2, 3]);
      expect(
        () => BackupFormat.parseHeader(file),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('builds a dated file name', () {
      expect(
        BackupFormat.fileName(DateTime(2026, 11, 3)),
        'storeflow_backup_2026-11-03.sfp',
      );
    });

    test('the payload round-trips the manifest and the database', () {
      final database = Uint8List.fromList(List<int>.generate(500, (i) => i % 256));
      final payload = BackupPayload(
        manifest: BackupManifest.fromJson(
          BackupFormat.manifest(
            schemaVersion: 1,
            appVersion: '1.0.0',
            createdAt: DateTime.utc(2026, 11, 3, 12),
            recordCounts: <String, int>{'products': 7, 'sales': 3},
            databaseSha256: 'abc',
          ),
        ),
        database: database,
      );

      final decoded = BackupPayload.decode(payload.encode());
      expect(decoded.manifest.schemaVersion, 1);
      expect(decoded.manifest.appVersion, '1.0.0');
      expect(decoded.manifest.recordCounts['products'], 7);
      expect(decoded.manifest.databaseSha256, 'abc');
      expect(decoded.manifest.createdAt, DateTime.utc(2026, 11, 3, 12));
      // The database is stored raw, not base64, so it comes back byte for byte.
      expect(decoded.database, database);
    });

    test('a truncated payload is rejected', () {
      expect(
        () => BackupPayload.decode(Uint8List.fromList(<int>[1, 0, 0])),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a payload whose manifest length overruns the file is rejected', () {
      // Claims a manifest of 1000 bytes but holds only a few.
      final bytes = Uint8List.fromList(<int>[0xE8, 0x03, 0x00, 0x00, 1, 2, 3]);
      expect(
        () => BackupPayload.decode(bytes),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('backup cipher', () {
    test('encrypts and decrypts a payload', () async {
      final cipher = fastCipher();
      final plaintext = Uint8List.fromList(utf8.encode('the shop data'));

      final encrypted = await cipher.encrypt(
        plaintext: plaintext,
        password: 'correct horse battery staple',
      );
      expect(encrypted.sublist(0, 4), BackupFormat.magic);
      // The plaintext must not appear in the file.
      expect(
        String.fromCharCodes(encrypted).contains('the shop data'),
        isFalse,
      );

      final decrypted = await cipher.decrypt(
        file: encrypted,
        password: 'correct horse battery staple',
      );
      expect(decrypted, plaintext);
    });

    test('the same input encrypts to two different files', () async {
      final cipher = fastCipher();
      final plaintext = Uint8List.fromList(utf8.encode('same'));
      final first = await cipher.encrypt(plaintext: plaintext, password: 'pw');
      final second = await cipher.encrypt(plaintext: plaintext, password: 'pw');

      // A fresh salt and nonce mean the ciphertext differs, which is what stops
      // anyone from telling that two backups hold the same data.
      expect(first, isNot(second));
    });

    test('a wrong password is refused', () async {
      final cipher = fastCipher();
      final encrypted = await cipher.encrypt(
        plaintext: Uint8List.fromList(utf8.encode('secret')),
        password: 'right',
      );
      expect(
        () => cipher.decrypt(file: encrypted, password: 'wrong'),
        throwsA(isA<BackupDecryptionException>()),
      );
    });

    test('a tampered ciphertext is refused', () async {
      final cipher = fastCipher();
      final encrypted = await cipher.encrypt(
        plaintext: Uint8List.fromList(utf8.encode('secret')),
        password: 'pw',
      );
      // Flip one byte in the middle of the ciphertext.
      final tampered = Uint8List.fromList(encrypted);
      tampered[BackupFormat.headerLength + 1] ^= 0xFF;

      // GCM authenticates the data, so the change is detected rather than
      // producing a corrupt database.
      expect(
        () => cipher.decrypt(file: tampered, password: 'pw'),
        throwsA(isA<BackupDecryptionException>()),
      );
    });

    test('an empty password is refused', () async {
      final cipher = fastCipher();
      expect(
        () => cipher.encrypt(
          plaintext: Uint8List.fromList(<int>[1]),
          password: '',
        ),
        throwsA(isA<BackupDecryptionException>()),
      );
    });

    test('the production cost is the documented one', () {
      // Guards against someone lowering the cost to speed up a test run and
      // leaving it lowered.
      final cipher = BackupCipher();
      expect(cipher.argon2MemoryKb, 65536);
      expect(cipher.argon2Iterations, 3);
      expect(cipher.argon2Parallelism, 4);
    });

    test('the digest is a stable SHA-256', () async {
      final digest = await Sha256Digest.ofBytes(utf8.encode('abc'));
      expect(
        digest,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('backup and restore', () {
    late Directory workspace;
    late String databasePath;
    late AppDatabase db;
    late BackupService backups;

    setUp(() async {
      workspace = Directory.systemTemp.createTempSync('sfp_test_');
      databasePath = p.join(workspace.path, 'storeflow.sqlite');
      db = AppDatabase.open(overridePath: databasePath);
      // Touch the database so the file exists before the first snapshot.
      await db.select(db.currencies).get();
      backups = BackupService(
        database: db,
        databasePath: databasePath,
        cipher: fastCipher(),
      );
    });

    tearDown(() async {
      try {
        await db.close();
      } catch (_) {
        // Already closed by a restore.
      }
      if (workspace.existsSync()) {
        await workspace.delete(recursive: true);
      }
    });

    /// Seeds a product and a completed sale, so a backup has something to hold.
    Future<int> seedData({String productName = 'Widget'}) async {
      final products = ProductRepository(db);
      final inventory = InventoryService(db);
      final sales = SaleRepository(db);
      final currencyId = (await (db.select(db.currencies)
                ..where((t) => t.isBase.equals(true)))
              .getSingle())
          .id;

      final productId = await products.create(
        name: productName,
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
              productName: productName,
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
      expect(result.invoiceNo, isNotEmpty);
      return productId;
    }

    /// Snapshot directories currently in the temporary directory.
    int snapshotDirectories() => Directory.systemTemp
        .listSync()
        .where((entry) => entry.path.contains('sfp_backup_'))
        .length;

    test('creates a backup and records the counts', () async {
      await seedData();
      final path = p.join(workspace.path, 'backup.sfp');
      final before = snapshotDirectories();

      final manifest = await backups.createBackup(
        destinationPath: path,
        password: 'shop-password',
      );

      expect(File(path).existsSync(), isTrue);
      expect(manifest.schemaVersion, db.schemaVersion);
      expect(manifest.recordCounts['products'], 1);
      expect(manifest.recordCounts['sales'], 1);
      expect(manifest.databaseSha256, isNotEmpty);
      // The snapshot working directory is cleaned up, leaving no growth.
      expect(snapshotDirectories(), before);
    });

    test('refuses to create a backup without a password', () async {
      await expectLater(
        backups.createBackup(
          destinationPath: p.join(workspace.path, 'x.sfp'),
          password: '   ',
        ),
        throwsA(isA<BackupException>()),
      );
    });

    test('inspects a backup without restoring it', () async {
      await seedData();
      final path = p.join(workspace.path, 'backup.sfp');
      await backups.createBackup(destinationPath: path, password: 'pw');

      final manifest = await backups.inspect(backupPath: path, password: 'pw');
      expect(manifest.recordCounts['products'], 1);
    });

    test('inspect fails on a wrong password', () async {
      await seedData();
      final path = p.join(workspace.path, 'backup.sfp');
      await backups.createBackup(destinationPath: path, password: 'pw');

      expect(
        () => backups.inspect(backupPath: path, password: 'nope'),
        throwsA(isA<BackupDecryptionException>()),
      );
    });

    test('previews a restore and passes every check', () async {
      await seedData();
      final path = p.join(workspace.path, 'backup.sfp');
      await backups.createBackup(destinationPath: path, password: 'pw');

      final preview = await backups.preview(backupPath: path, password: 'pw');
      expect(preview.canRestore, isTrue);
      expect(preview.checks.every((check) => check.passed), isTrue);
      expect(
        preview.checks.map((check) => check.name),
        containsAll(<String>['manifest', 'schema', 'digest', 'sqlite-header']),
      );
    });

    test('a corrupted backup is rejected before anything is restored', () async {
      await seedData();
      final path = p.join(workspace.path, 'backup.sfp');
      await backups.createBackup(destinationPath: path, password: 'pw');

      // Corrupt a byte of the payload.
      final bytes = await File(path).readAsBytes();
      bytes[bytes.length - 5] ^= 0xFF;
      await File(path).writeAsBytes(bytes);

      expect(
        () => backups.preview(backupPath: path, password: 'pw'),
        throwsA(isA<BackupDecryptionException>()),
      );
      // The live database is untouched.
      expect(File(databasePath).existsSync(), isTrue);
    });

    test('a missing file is reported clearly', () async {
      expect(
        () => backups.inspect(
          backupPath: p.join(workspace.path, 'absent.sfp'),
          password: 'pw',
        ),
        throwsA(isA<BackupException>()),
      );
    });

    test('restores a backup over the live database', () async {
      await seedData(productName: 'Widget');
      final path = p.join(workspace.path, 'backup.sfp');
      await backups.createBackup(destinationPath: path, password: 'pw');

      // Change the data after the backup: a second product appears.
      await seedData(productName: 'Gadget');
      final before = await db.select(db.products).get();
      expect(before, hasLength(2));

      final result = await backups.restore(backupPath: path, password: 'pw');
      expect(result.manifest.recordCounts['products'], 1);
      // The replaced database is kept, so a mistaken restore is reversible.
      expect(result.previousDatabasePath, isNotNull);
      expect(File(result.previousDatabasePath!).existsSync(), isTrue);

      // Reopen and confirm the restored state.
      final restored = backups.reopen();
      final products = await restored.select(restored.products).get();
      expect(products, hasLength(1));
      expect(products.single.name, 'Widget');
      await restored.close();
    });

    test('a wrong password cannot start a restore', () async {
      await seedData();
      final path = p.join(workspace.path, 'backup.sfp');
      await backups.createBackup(destinationPath: path, password: 'right');

      await expectLater(
        backups.restore(backupPath: path, password: 'wrong'),
        throwsA(isA<BackupDecryptionException>()),
      );

      // The live database still opens and still holds its data.
      final stillThere = await db.select(db.products).get();
      expect(stillThere, isNotEmpty);
    });

    test('data survives a restore and reopening', () async {
      final productId = await seedData(productName: 'Persisted');
      final path = p.join(workspace.path, 'backup.sfp');
      await backups.createBackup(destinationPath: path, password: 'pw');

      await backups.restore(backupPath: path, password: 'pw');
      final restored = backups.reopen();

      final product = await ProductRepository(restored).findById(productId);
      expect(product, isNotNull);
      expect(product!.name, 'Persisted');

      // The inventory ledger and the sale came back too.
      final movements = await restored.select(restored.inventoryMovements).get();
      expect(movements, isNotEmpty);
      final saleRows = await restored.select(restored.sales).get();
      expect(saleRows, hasLength(1));
      expect(saleRows.single.status, DocumentStatus.posted.wireValue);

      await restored.close();
    });

    test('an interrupted write never leaves a half-written backup', () async {
      await seedData();
      final path = p.join(workspace.path, 'backup.sfp');
      await backups.createBackup(destinationPath: path, password: 'pw');

      // A leftover partial file from an earlier crash must not be mistaken for a
      // backup, and the next run must replace it.
      final partial = File('$path.partial');
      await partial.writeAsBytes(<int>[0, 1, 2, 3]);
      await backups.createBackup(destinationPath: path, password: 'pw');

      final manifest = await backups.inspect(backupPath: path, password: 'pw');
      expect(manifest.schemaVersion, db.schemaVersion);
    });
  });

  group('authentication', () {
    late AppDatabase db;
    late AuthService auth;

    setUp(() async {
      db = AppDatabase.memory();
      auth = AuthService(
        database: db,
        argon2MemoryKb: 256,
        argon2Iterations: 1,
        argon2Parallelism: 1,
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('no PIN is set on a fresh database', () async {
      expect(await auth.isPinSet(), isFalse);
    });

    test('sets a PIN and verifies it', () async {
      await auth.setPin(pin: '1234');
      expect(await auth.isPinSet(), isTrue);
      expect(await auth.verify(pin: '1234'), isTrue);
      expect(await auth.verify(pin: '9999'), isFalse);
    });

    test('the PIN itself is never stored', () async {
      await auth.setPin(pin: '4321');
      final user = await db.select(db.users).getSingle();

      expect(user.pinHash, isNotNull);
      expect(user.pinSalt, isNotNull);
      expect(user.pinAlgorithm, AuthService.algorithm);
      // Neither the hash nor the salt may contain the PIN.
      expect(user.pinHash, isNot(contains('4321')));
      expect(user.pinSalt, isNot(contains('4321')));
      // The hash is base64 of 32 bytes.
      expect(base64Decode(user.pinHash!).length, 32);
    });

    test('the same PIN hashes differently on two accounts', () async {
      await auth.setPin(pin: '1234');
      final first = (await db.select(db.users).getSingle()).pinHash;

      await auth.clearPin(currentPin: '1234');
      await auth.setPin(pin: '1234');
      final second = (await db.select(db.users).getSingle()).pinHash;

      // A fresh salt per set means identical PINs do not produce identical hashes.
      expect(first, isNot(second));
    });

    test('changing a PIN requires the current one', () async {
      await auth.setPin(pin: '1234');
      expect(
        () => auth.setPin(pin: '5678'),
        throwsA(isA<AuthException>()),
      );
      expect(
        () => auth.setPin(pin: '5678', currentPin: '0000'),
        throwsA(isA<AuthException>()),
      );

      await auth.setPin(pin: '5678', currentPin: '1234');
      expect(await auth.verify(pin: '5678'), isTrue);
      expect(await auth.verify(pin: '1234'), isFalse);
    });

    test('rejects a PIN of the wrong shape', () async {
      expect(() => auth.setPin(pin: '12'), throwsA(isA<AuthException>()));
      expect(() => auth.setPin(pin: 'abcdef'), throwsA(isA<AuthException>()));
      expect(
        () => auth.setPin(pin: '1234567890123'),
        throwsA(isA<AuthException>()),
      );
    });

    test('clearing the PIN requires the current one', () async {
      await auth.setPin(pin: '1234');
      expect(
        () => auth.clearPin(currentPin: '0000'),
        throwsA(isA<AuthException>()),
      );
      await auth.clearPin(currentPin: '1234');
      expect(await auth.isPinSet(), isFalse);
      expect(await auth.verify(pin: '1234'), isFalse);
    });

    test('the delay grows after repeated failures and is capped', () {
      expect(auth.delayAfter(0), Duration.zero);
      expect(auth.delayAfter(4), Duration.zero);
      expect(auth.delayAfter(5), const Duration(seconds: 1));
      expect(auth.delayAfter(6), const Duration(seconds: 2));
      // Capped, so the owner is never locked out for long.
      expect(auth.delayAfter(50), const Duration(seconds: 30));
    });
  });

  group('audit log', () {
    late AppDatabase db;
    late AuditService audit;

    setUp(() async {
      db = AppDatabase.memory();
      audit = AuditService(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('records an action with its details', () async {
      await audit.log(
        action: 'product_created',
        entityType: 'product',
        entityId: 7,
        description: 'Added a product',
        payload: <String, Object?>{'name': 'Widget'},
      );

      final entries = await audit.recent();
      expect(entries, hasLength(1));
      expect(entries.single.action, 'product_created');
      expect(entries.single.entityType, 'product');
      expect(entries.single.entityId, 7);
      expect(entries.single.payload, contains('Widget'));
    });

    test('a sign-in is recorded without the PIN', () async {
      final auth = AuthService(
        database: db,
        audit: audit,
        argon2MemoryKb: 256,
        argon2Iterations: 1,
        argon2Parallelism: 1,
      );
      await auth.setPin(pin: '1234');
      await auth.verify(pin: '1234');
      await auth.verify(pin: '0000');

      final entries = await audit.recent();
      final actions = entries.map((entry) => entry.action).toList();
      expect(actions, contains('pin_set'));
      expect(actions, contains('login_succeeded'));
      expect(actions, contains('login_failed'));

      // No entry may carry the PIN, in any field.
      for (final entry in entries) {
        final text = '${entry.description} ${entry.payload}';
        expect(text, isNot(contains('1234')));
      }
    });

    test('the newest entry comes first', () async {
      await audit.log(action: 'first', entityType: 'x');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await audit.log(action: 'second', entityType: 'x');

      final entries = await audit.recent();
      expect(entries.first.action, 'second');
    });
  });
}
