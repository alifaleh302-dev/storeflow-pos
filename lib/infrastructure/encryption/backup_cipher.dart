import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'backup_format.dart';

/// The authenticated encryption used for backups.
///
/// AES-256-GCM is used because it both hides the data and detects any change to
/// it. A backup that has been edited, truncated or corrupted fails to decrypt
/// rather than restoring a damaged database.
///
/// The password is stretched with Argon2id. Argon2id is deliberately slow and
/// memory-hungry, which is what makes guessing a password expensive. The default
/// cost is chosen to take a noticeable but tolerable moment on a desktop and a
/// little longer on a phone; it is a tunable, not a law of nature.
class BackupCipher {
  BackupCipher({
    this.argon2MemoryKb = 65536,
    this.argon2Iterations = 3,
    this.argon2Parallelism = 4,
  });

  /// Memory used for key derivation, in kibibytes.
  final int argon2MemoryKb;

  /// Number of passes over that memory.
  final int argon2Iterations;

  /// Lanes of parallel work.
  final int argon2Parallelism;

  static const int keyLength = 32; // AES-256

  AesGcm get _cipher => AesGcm.with256bits();

  Argon2id get _kdf => Argon2id(
        memory: argon2MemoryKb,
        iterations: argon2Iterations,
        parallelism: argon2Parallelism,
        hashLength: keyLength,
      );

  /// Encrypts [plaintext] with [password].
  ///
  /// A fresh salt and nonce are generated for every call, so the same plaintext
  /// and password never produce the same file twice.
  Future<Uint8List> encrypt({
    required Uint8List plaintext,
    required String password,
    RandomBytes? random,
  }) async {
    final source = random ?? _defaultRandom;
    final salt = source(BackupFormat.saltLength);
    final nonce = source(BackupFormat.nonceLength);

    final key = await _deriveKey(password, salt);
    final secretBox = await _cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );

    final header = BackupFormat.encodeHeader(salt: salt, nonce: nonce);
    final output = BytesBuilder();
    output.add(header);
    output.add(secretBox.cipherText);
    output.add(secretBox.mac.bytes);
    return output.toBytes();
  }

  /// Decrypts a backup file with [password].
  ///
  /// Throws [BackupDecryptionException] when the password is wrong or the file has
  /// been altered. The two cases are not distinguished, because telling an
  /// attacker which one it was is a small gift they should not receive.
  Future<Uint8List> decrypt({
    required Uint8List file,
    required String password,
  }) async {
    final header = BackupFormat.parseHeader(file);
    if (header.ciphertext.length < BackupFormat.tagLength) {
      throw const BackupFormatException('The backup payload is truncated');
    }

    final cipherText = header.ciphertext.sublist(
      0,
      header.ciphertext.length - BackupFormat.tagLength,
    );
    final mac = Mac(
      header.ciphertext.sublist(header.ciphertext.length - BackupFormat.tagLength),
    );

    final key = await _deriveKey(password, header.salt);
    try {
      final clear = await _cipher.decrypt(
        SecretBox(cipherText, nonce: header.nonce, mac: mac),
        secretKey: key,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const BackupDecryptionException(
        'The password is wrong, or the backup file has been damaged',
      );
    }
  }

  /// Derives the encryption key from [password] and [salt].
  Future<SecretKey> _deriveKey(String password, List<int> salt) {
    if (password.isEmpty) {
      throw const BackupDecryptionException(
        'A backup password is required',
      );
    }
    return _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static Uint8List _defaultRandom(int length) {
    final random = SecureRandom.system;
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}

/// Supplies random bytes. Overridable so a test can make encryption repeatable.
typedef RandomBytes = Uint8List Function(int length);

/// A backup could not be decrypted.
class BackupDecryptionException implements Exception {
  const BackupDecryptionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Computes a SHA-256 digest, used to check a restored database matches the one
/// that was backed up.
abstract final class Sha256Digest {
  static Future<String> ofBytes(List<int> bytes) async {
    final hash = await Sha256().hash(bytes);
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
