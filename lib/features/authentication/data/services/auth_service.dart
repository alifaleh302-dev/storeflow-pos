import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';

import '../../../../core/database/audit_service.dart';
import '../../../../infrastructure/database/app_database.dart';

/// The owner's PIN authentication.
///
/// ## What is stored
///
/// The PIN itself is never written anywhere. Only a derived hash and its salt are
/// stored, in the `users` table, and a successful verification writes an audit
/// entry. There is one owner account, but the schema and this service are written
/// so that more users can be added without a migration.
///
/// ## Why Argon2id
///
/// A short numeric PIN has very little entropy, so a fast hash would be brute
/// forced in seconds. Argon2id is deliberately slow and memory-hungry, which is
/// what makes guessing expensive. The parameters are the same ones the backup
/// cipher uses, so there is one story about password stretching in the codebase
/// rather than two.
class AuthService {
  AuthService({
    required AppDatabase database,
    AuditService? audit,
    this.argon2MemoryKb = 65536,
    this.argon2Iterations = 3,
    this.argon2Parallelism = 4,
  })  : _db = database,
        _audit = audit ?? AuditService(database);

  final AppDatabase _db;
  final AuditService _audit;

  final int argon2MemoryKb;
  final int argon2Iterations;
  final int argon2Parallelism;

  /// The algorithm name recorded alongside the hash, so a future change can tell
  /// which parameters produced an existing hash.
  static const String algorithm = 'argon2id';

  /// The shortest PIN accepted.
  static const int minimumPinLength = 4;

  /// The longest PIN accepted, so a long PIN cannot be used to make verification
  /// slow on purpose.
  static const int maximumPinLength = 12;

  /// Failed attempts before a delay is imposed.
  static const int attemptsBeforeDelay = 5;

  static const int _saltLength = 16;
  static const int _hashLength = 32;

  Argon2id get _kdf => Argon2id(
        memory: argon2MemoryKb,
        iterations: argon2Iterations,
        parallelism: argon2Parallelism,
        hashLength: _hashLength,
      );

  /// Whether the owner has set a PIN yet.
  Future<bool> isPinSet() async {
    final user = await _owner();
    return user?.pinHash != null && user!.pinHash!.isNotEmpty;
  }

  /// Sets or replaces the owner's PIN.
  ///
  /// [currentPin] is required when a PIN already exists, so that someone at an
  /// unlocked machine cannot silently change it.
  Future<void> setPin({
    required String pin,
    String? currentPin,
  }) async {
    _validatePinFormat(pin);

    final user = await _owner();
    if (user == null) {
      throw const AuthException('There is no owner account to set a PIN for');
    }

    if (user.pinHash != null && user.pinHash!.isNotEmpty) {
      if (currentPin == null) {
        throw const AuthException('The current PIN is required to change it');
      }
      final ok = await verify(pin: currentPin, recordAudit: false);
      if (!ok) {
        await _audit.log(
          action: 'pin_change_failed',
          entityType: 'user',
          entityId: user.id,
          description:
              'A PIN change was refused because the current PIN was wrong',
        );
        throw const AuthException('The current PIN is wrong');
      }
    }

    final salt = _randomBytes(_saltLength);
    final hash = await _derive(pin, salt);

    await (_db.update(_db.users)..where((t) => t.id.equals(user.id))).write(
      UsersCompanion(
        pinHash: Value(base64Encode(hash)),
        pinSalt: Value(base64Encode(salt)),
        pinAlgorithm: const Value(algorithm),
        updatedAt: Value(DateTime.now().toUtc().toIso8601String()),
      ),
    );

    await _audit.log(
      action: user.pinHash == null ? 'pin_set' : 'pin_changed',
      entityType: 'user',
      entityId: user.id,
      description: 'The owner PIN was set',
    );
  }

  /// Checks [pin]. Never reveals whether the account or the PIN was wrong.
  Future<bool> verify({required String pin, bool recordAudit = true}) async {
    final user = await _owner();
    if (user == null || user.pinHash == null || user.pinSalt == null) {
      return false;
    }

    final salt = base64Decode(user.pinSalt!);
    final expected = base64Decode(user.pinHash!);
    final actual = await _derive(pin, salt);

    final matches = _constantTimeEquals(expected, actual);
    if (recordAudit) {
      await _audit.log(
        action: matches ? 'login_succeeded' : 'login_failed',
        entityType: 'user',
        entityId: user.id,
        description:
            matches ? 'The owner signed in' : 'A sign-in attempt failed',
      );
    }
    return matches;
  }

  /// Removes the PIN, returning the application to first-run behaviour.
  Future<void> clearPin({required String currentPin}) async {
    if (!await verify(pin: currentPin, recordAudit: false)) {
      throw const AuthException('The current PIN is wrong');
    }
    final user = await _owner();
    if (user == null) return;
    await (_db.update(_db.users)..where((t) => t.id.equals(user.id))).write(
      const UsersCompanion(
        pinHash: Value(null),
        pinSalt: Value(null),
        pinAlgorithm: Value(null),
      ),
    );
    await _audit.log(
      action: 'pin_cleared',
      entityType: 'user',
      entityId: user.id,
      description: 'The owner PIN was removed',
    );
  }

  /// How long to wait after [failedAttempts] consecutive failures.
  ///
  /// A short PIN can be guessed given unlimited attempts, so the delay grows with
  /// each failure. It is a speed bump, not a lockout: the specification calls for
  /// one local user, and locking the owner out of their own shop would be worse
  /// than a slower guess. The delay is returned rather than applied so the caller
  /// decides how to present it.
  Duration delayAfter(int failedAttempts) {
    if (failedAttempts < attemptsBeforeDelay) return Duration.zero;
    final steps = failedAttempts - attemptsBeforeDelay;
    final seconds = min(30, 1 << min(steps, 5));
    return Duration(seconds: seconds);
  }

  Future<UserRow?> _owner() async {
    return (_db.select(_db.users)
          ..where((t) => t.isOwner.equals(true) & t.isActive.equals(true))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<Uint8List> _derive(String pin, List<int> salt) async {
    final key = await _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(pin)),
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  void _validatePinFormat(String pin) {
    if (pin.length < minimumPinLength || pin.length > maximumPinLength) {
      throw AuthException(
        'The PIN must be between $minimumPinLength and $maximumPinLength digits',
      );
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      throw const AuthException('The PIN must contain digits only');
    }
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// Compares two byte sequences without leaking where they first differ.
  ///
  /// A plain equality check returns as soon as it finds a difference, and how long
  /// that takes says something about how much of the guess was right.
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }
}

/// An authentication operation that could not be completed.
class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
