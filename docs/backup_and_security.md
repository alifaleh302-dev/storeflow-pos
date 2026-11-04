# Backup, restore and security

This document describes how StoreFlow POS protects the shop's data: the encrypted
backup format, the restore procedure, the owner PIN, and the audit log.

Nothing here is aspirational. Every mechanism described is implemented and covered
by a test, and the limitations are stated at the end rather than left out.

## Backup file format

A backup is a binary container followed by an encrypted payload. The extension is
`.sfp` and a typical name is `storeflow_backup_2026-11-03.sfp`.

```text
offset  size  field
0       4     magic "SFPB"
4       2     format version, little-endian
6       16    Argon2id salt
22      12    AES-GCM nonce
34      ...   ciphertext, then the 16-byte GCM authentication tag
```

The header is not secret. It is also not trusted: every field is length-checked
before use, and the version must match the one this build writes. A file whose
magic is wrong, that is too short, or that was written by a different format
version is refused with a specific message rather than a crash.

### What is inside

Inside the encrypted payload is a length-prefixed JSON manifest followed by the
raw database bytes:

```text
4 bytes   manifest length, little-endian
N bytes   manifest, UTF-8 JSON
rest      the SQLite database file
```

The manifest holds the schema version, the application version, the creation time,
row counts for the tables a shop would notice losing, and a SHA-256 digest of the
database. The manifest is encrypted along with the database, so the shop name and
the record counts cannot be read from a backup file without the password.

The database is stored raw rather than base64-encoded, so a backup is not a third
larger than the data it holds, and the manifest boundary is unambiguous rather than
depending on the database never containing a particular byte.

## Encryption

| Concern | Choice |
|---|---|
| Cipher | AES-256-GCM |
| Key derivation | Argon2id |
| Salt | 16 bytes, fresh per backup |
| Nonce | 12 bytes, fresh per backup |
| Tag | 16 bytes, appended to the ciphertext |

GCM is used because it both hides the data and detects any change to it. A backup
that has been edited, truncated or corrupted fails to decrypt rather than restoring
a damaged database. This is tested by flipping a single byte in the ciphertext and
confirming the decryption is refused.

Argon2id is deliberately slow and memory-hungry, which is what makes guessing the
password expensive. The production cost is 64 MiB of memory, 3 iterations and 4
lanes. A test asserts those exact values, so that lowering the cost to speed up a
test run cannot be committed by accident.

A fresh salt and nonce are generated for every backup, so encrypting the same
database twice with the same password produces two different files. A test checks
this.

## Creating a backup

1. A consistent snapshot of the live database is taken with the SQLite backup API.
2. The snapshot is hashed and a manifest is built.
3. The manifest and the snapshot are encrypted.
4. The result is written to a sibling `.partial` file and then renamed into place.

Step 4 matters: an interrupted write never leaves a half-written file where a good
backup used to be.

Step 1 also has a subtlety worth recording. The database runs in write-ahead
logging mode, so recent commits live in the `-wal` file rather than the main file.
The snapshot connection is opened read-write for that reason: a read-only
connection cannot read the write-ahead log and would copy a stale or empty
database. The backup API also returns a lazy stream that does no work until it is
listened to, so it must be drained. Both mistakes were made and caught by tests
during development; ignoring either produces a backup that looks fine and restores
nothing.

## Restoring a backup

The order is deliberate, because a restore is the one operation that can destroy
the shop's data:

1. Read and decrypt the file. A wrong password stops here.
2. Validate the manifest, the schema version, the digest and the SQLite header.
3. Write the decrypted database to a staged file next to the live one.
4. Run `PRAGMA integrity_check` on the staged file, opened on its own.
5. Close the live database.
6. Rename the live database aside and the staged file into its place.
7. Keep the replaced database as `<database>.previous`.

Nothing touches the live database until the replacement has passed every check.
The database that was replaced is kept, so a restore that turns out to be a mistake
is itself reversible.

If the swap fails part way through, the previous database is renamed back.

## Owner PIN

The owner signs in with a numeric PIN of 4 to 12 digits.

The PIN itself is never written anywhere. Only an Argon2id hash and its salt are
stored, in the `users` table, along with the algorithm name so a future change can
tell how an existing hash was produced. A test confirms that neither the hash nor
the salt contains the PIN, and that two accounts with the same PIN have different
hashes.

Verification compares the derived bytes in constant time. A plain equality check
returns as soon as it finds a difference, and how long that takes says something
about how much of a guess was right.

Changing or clearing the PIN requires the current one, so someone at an unlocked
machine cannot silently change it.

After five consecutive failures a delay is imposed, growing to a 30-second cap. It
is a speed bump, not a lockout: the specification calls for a single local user,
and locking the owner out of their own shop would be worse than a slower guess. The
delay is returned to the caller rather than applied by this service, so the
interface decides how to present it.

## Audit log

Actions are written to an append-only `audit_logs` table. Rows are never updated or
deleted. Recorded actions include setting and changing the PIN, failed PIN changes,
sign-in success and failure, and clearing the PIN.

Audit rows never contain the PIN, a hash, or a backup password. A test walks every
audit entry produced by a sign-in sequence and asserts that the PIN appears in none
of them.

## Known limitations

- **The database file itself is not encrypted at rest.** Anyone with the file can
  read the shop's data. Only backups are encrypted. Encrypting the live database
  would need SQLCipher or an equivalent, which is not in the dependency set. This
  is a deliberate deferral, not an oversight.
- **There is no key recovery.** A forgotten backup password means the backup cannot
  be read. There is no back door, by design.
- **The PIN protects the application, not the file.** It stops someone using the
  interface; it does not stop someone copying the database file.
- **Restore replaces the whole database.** There is no merge, and no partial
  restore of a single table.
- **Only one user account exists.** The schema and the service are written so more
  users can be added without a migration, but multi-user permissions are not
  implemented and are not claimed.
- **No physical device was used to test any of this.** It is all covered by
  automated tests on the desktop platform.
