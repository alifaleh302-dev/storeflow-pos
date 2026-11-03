import 'dart:convert';

import 'package:drift/drift.dart';

import '../../infrastructure/database/app_database.dart';
import '../utils/timestamps.dart';

/// Writes to the append-only `audit_logs` table.
///
/// Audit rows are never updated or deleted. They record *what* changed and
/// enough identifiers to reconstruct the change, but never secrets, PIN hashes
/// or backup passwords.
class AuditService {
  const AuditService(this._db);

  final AppDatabase _db;

  /// Records an action. [payload] must contain no sensitive values.
  Future<void> log({
    required String action,
    required String entityType,
    int? entityId,
    String? description,
    Map<String, Object?>? payload,
    int? userId,
  }) async {
    await _db.into(_db.auditLogs).insert(
          AuditLogsCompanion.insert(
            action: action,
            entityType: entityType,
            entityId: Value(entityId),
            description: Value(description),
            payload: Value(payload == null ? null : jsonEncode(payload)),
            userId: Value(userId),
            createdAt: nowStorageTimestamp(),
          ),
        );
  }

  /// Most recent audit entries, newest first.
  Future<List<AuditLogRow>> recent({int limit = 200}) {
    return (_db.select(_db.auditLogs)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
  }
}
