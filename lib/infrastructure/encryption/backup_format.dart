import 'dart:convert';
import 'dart:typed_data';

/// The layout of a StoreFlow backup file.
///
/// ## Format
///
/// A backup is a small binary container followed by the encrypted payload:
///
/// ```text
/// offset  size  field
/// 0       4     magic "SFPB"
/// 4       2     format version, little-endian
/// 6       16    Argon2id salt
/// 22      12    AES-GCM nonce
/// 34      ...   ciphertext, followed by the 16-byte GCM tag
/// ```
///
/// The header is not secret, but it is not trusted either. Every field is
/// length-checked before it is used, and the ciphertext is authenticated by GCM,
/// so a file that has been edited in any way fails to decrypt rather than
/// producing a corrupt database.
///
/// The password never appears in the file. It is turned into a key with Argon2id
/// using the stored salt, and that key decrypts the payload. The salt and nonce
/// are fresh for every backup, so encrypting the same database twice with the same
/// password produces two different files.
class BackupFormat {
  const BackupFormat._();

  /// The four bytes at the start of every backup.
  static const List<int> magic = <int>[0x53, 0x46, 0x50, 0x42]; // "SFPB"

  /// The format version this build writes.
  static const int currentVersion = 1;

  /// Bytes of Argon2id salt.
  static const int saltLength = 16;

  /// Bytes of AES-GCM nonce. Twelve is the size GCM is designed for.
  static const int nonceLength = 12;

  /// Bytes of the GCM authentication tag.
  static const int tagLength = 16;

  /// The fixed part of the file before the ciphertext.
  static const int headerLength = 4 + 2 + saltLength + nonceLength;

  /// The file extension.
  static const String extension = 'sfp';

  /// The manifest stored inside the encrypted payload.
  ///
  /// The manifest is encrypted along with the database, so a reader cannot learn
  /// the shop name or the record counts from a backup file without the password.
  static Map<String, dynamic> manifest({
    required int schemaVersion,
    required String appVersion,
    required DateTime createdAt,
    required Map<String, int> recordCounts,
    required String databaseSha256,
  }) {
    return <String, dynamic>{
      'schemaVersion': schemaVersion,
      'appVersion': appVersion,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'recordCounts': recordCounts,
      'databaseSha256': databaseSha256,
      'formatVersion': currentVersion,
    };
  }

  /// Encodes the header for [salt] and [nonce].
  static Uint8List encodeHeader({
    required List<int> salt,
    required List<int> nonce,
    int version = currentVersion,
  }) {
    if (salt.length != saltLength) {
      throw ArgumentError.value(salt.length, 'salt', 'must be $saltLength bytes');
    }
    if (nonce.length != nonceLength) {
      throw ArgumentError.value(
          nonce.length, 'nonce', 'must be $nonceLength bytes');
    }
    final bytes = BytesBuilder();
    bytes.add(magic);
    // Version is two bytes, little-endian.
    bytes.add(<int>[version & 0xFF, (version >> 8) & 0xFF]);
    bytes.add(salt);
    bytes.add(nonce);
    return bytes.toBytes();
  }

  /// A parsed header.
  static BackupHeader parseHeader(Uint8List file) {
    if (file.length < headerLength) {
      throw const BackupFormatException(
        'The file is too small to be a backup',
      );
    }
    for (var i = 0; i < magic.length; i++) {
      if (file[i] != magic[i]) {
        throw const BackupFormatException(
          'This is not a StoreFlow backup file',
        );
      }
    }
    final version = file[4] | (file[5] << 8);
    if (version != currentVersion) {
      throw BackupFormatException(
        'This backup was written by a different version of the application '
        '(format $version, this build reads $currentVersion)',
      );
    }
    final salt = file.sublist(magic.length + 2, magic.length + 2 + saltLength);
    final nonce = file.sublist(
      magic.length + 2 + saltLength,
      headerLength,
    );
    return BackupHeader(
      version: version,
      salt: salt,
      nonce: nonce,
      ciphertext: file.sublist(headerLength),
    );
  }

  /// Builds a backup file name for [date].
  static String fileName(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return 'storeflow_backup_$year-$month-$day.$extension';
  }
}

/// The parsed header of a backup file.
class BackupHeader {
  const BackupHeader({
    required this.version,
    required this.salt,
    required this.nonce,
    required this.ciphertext,
  });

  final int version;
  final List<int> salt;
  final List<int> nonce;

  /// The encrypted payload, with the authentication tag at the end.
  final List<int> ciphertext;
}

/// A backup file that cannot be read.
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A manifest read back from a decrypted backup.
class BackupManifest {
  const BackupManifest({
    required this.schemaVersion,
    required this.appVersion,
    required this.createdAt,
    required this.recordCounts,
    required this.databaseSha256,
    required this.formatVersion,
  });

  final int schemaVersion;
  final String appVersion;
  final DateTime createdAt;
  final Map<String, int> recordCounts;
  final String databaseSha256;
  final int formatVersion;

  static BackupManifest fromJson(Map<String, dynamic> json) {
    final counts = <String, int>{};
    final rawCounts = json['recordCounts'];
    if (rawCounts is Map) {
      rawCounts.forEach((key, value) {
        if (value is int) counts['$key'] = value;
      });
    }
    return BackupManifest(
      schemaVersion: json['schemaVersion'] as int? ?? 0,
      appVersion: json['appVersion'] as String? ?? 'unknown',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      recordCounts: counts,
      databaseSha256: json['databaseSha256'] as String? ?? '',
      formatVersion: json['formatVersion'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => BackupFormat.manifest(
        schemaVersion: schemaVersion,
        appVersion: appVersion,
        createdAt: createdAt,
        recordCounts: recordCounts,
        databaseSha256: databaseSha256,
      );
}

/// The plaintext payload of a backup: the manifest and the database image.
class BackupPayload {
  const BackupPayload({required this.manifest, required this.database});

  final BackupManifest manifest;
  final Uint8List database;

  /// Serialises the payload as a length-prefixed JSON manifest followed by the
  /// raw database bytes.
  ///
  /// Length-prefixing the manifest means the database is not base64-encoded, so a
  /// backup is not a third larger than the data it holds, and the split point is
  /// unambiguous rather than depending on the database never containing a brace.
  Uint8List encode() {
    final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
    final bytes = BytesBuilder();
    bytes.add(_uint32(manifestBytes.length));
    bytes.add(manifestBytes);
    bytes.add(database);
    return bytes.toBytes();
  }

  /// Parses a payload produced by [encode].
  static BackupPayload decode(Uint8List bytes) {
    if (bytes.length < 4) {
      throw const BackupFormatException('The backup payload is truncated');
    }
    final manifestLength = bytes[0] |
        (bytes[1] << 8) |
        (bytes[2] << 16) |
        (bytes[3] << 24);
    if (manifestLength <= 0 || bytes.length < 4 + manifestLength) {
      throw const BackupFormatException('The backup payload is truncated');
    }
    final manifestJson = utf8.decode(
      bytes.sublist(4, 4 + manifestLength),
    );
    final decoded = jsonDecode(manifestJson);
    if (decoded is! Map<String, dynamic>) {
      throw const BackupFormatException('The backup manifest is not readable');
    }
    return BackupPayload(
      manifest: BackupManifest.fromJson(decoded),
      database: Uint8List.sublistView(bytes, 4 + manifestLength),
    );
  }

  static List<int> _uint32(int value) => <int>[
        value & 0xFF,
        (value >> 8) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 24) & 0xFF,
      ];
}
