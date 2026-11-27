import 'package:sqflite/sqflite.dart';

import '../../../core/database/app_database.dart';
import '../domain/sync_operation.dart';

class SyncRepository {
  final AppDatabase _appDatabase;

  SyncRepository({AppDatabase? appDatabase})
    : _appDatabase = appDatabase ?? AppDatabase.instance;

  Future<List<SyncOperation>> getAllOperations() async {
    final db = await _appDatabase.database;

    final results = await db.query(
      'sync_operations',
      orderBy: 'created_at ASC, seq ASC',
    );

    return results.map(SyncOperation.fromMap).toList();
  }

  Future<List<SyncOperation>> getOperationsForHousehold(
    String householdId,
  ) async {
    final db = await _appDatabase.database;

    final results = await db.query(
      'sync_operations',
      where: 'household_id = ?',
      whereArgs: [householdId],
      orderBy: 'seq ASC',
    );

    return results.map(SyncOperation.fromMap).toList();
  }

  Future<List<SyncOperation>> getAllPendingOperations() async {
    final db = await _appDatabase.database;

    final results = await db.query(
      'sync_operations',
      where: "state IN ('pending', 'retrying')",
      orderBy: 'created_at ASC',
    );

    return results.map(SyncOperation.fromMap).toList();
  }

  Future<List<SyncOperation>> getReadyOperations({
    required DateTime now,
  }) async {
    final db = await _appDatabase.database;

    final results = await db.query(
      'sync_operations',
      where:
          "state = 'pending' OR "
          "(state = 'retrying' AND next_retry_at IS NOT NULL AND next_retry_at <= ?)",
      whereArgs: [now.toIso8601String()],
      orderBy: 'created_at ASC, seq ASC',
    );

    return results.map(SyncOperation.fromMap).toList();
  }

  Future<SyncOperation?> getNextOperationForHousehold(
    String householdId,
  ) async {
    final db = await _appDatabase.database;

    final results = await db.query(
      'sync_operations',
      where: "household_id = ? AND state != 'completed'",
      whereArgs: [householdId],
      orderBy: 'seq ASC',
      limit: 1,
    );

    if (results.isEmpty) {
      return null;
    }
    return SyncOperation.fromMap(results.single);
  }

  Future<void> updateOperation(SyncOperation operation) async {
    final db = await _appDatabase.database;

    final updated = await db.update(
      'sync_operations',
      operation.toMap(),
      where: 'op_id = ?',
      whereArgs: [operation.opId],
    );
    if (updated == 0) {
      throw StateError('Sync operation not found: ${operation.opId}');
    }
  }

  Future<void> saveRetryState(SyncOperation operation) async {
    final db = await _appDatabase.database;

    final updated = await db.update(
      'sync_operations',
      operation.toMap(),
      where: 'op_id = ?',
      whereArgs: [operation.opId],
    );
    if (updated == 0) {
      throw StateError('Sync operation not found: ${operation.opId}');
    }
  }

  /// Saves [operation] and marks every later unresolved operation for its
  /// household as blocked. Completed, parked, and rejected rows are left
  /// unchanged.
  Future<void> parkOperation(SyncOperation operation) {
    return _saveAndBlockLater(operation);
  }

  /// Saves a permanently rejected [operation] and blocks later unresolved
  /// operations for the same household.
  Future<void> rejectOperation(SyncOperation operation) {
    return _saveAndBlockLater(operation);
  }

  /// Resets a parked operation so it can be sent again.
  ///
  /// Only `attempt_count`, `state`, `next_retry_at`, and `last_error` change.
  /// Later operations stay blocked.
  Future<void> retryParkedOperation(String opId) async {
    final db = await _appDatabase.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'sync_operations',
        where: 'op_id = ?',
        whereArgs: [opId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Sync operation not found: $opId');
      }
      final operation = SyncOperation.fromMap(rows.single);
      if (operation.state != 'parked') {
        throw StateError('Sync operation $opId is not parked');
      }
      final updated = await txn.update(
        'sync_operations',
        const {
          'state': 'pending',
          'attempt_count': 0,
          'next_retry_at': null,
          'last_error': null,
        },
        where: 'op_id = ?',
        whereArgs: [opId],
      );
      if (updated != 1) {
        throw StateError('Sync operation not found: $opId');
      }
    });
  }

  /// Removes a rejected operation and repairs the household queue.
  ///
  /// A rejected update is deleted on its own, then the next blocked operation
  /// is released when nothing earlier still blocks it. A rejected create also
  /// removes its dependent operations. The local household is deleted only
  /// when it has no server ID.
  Future<void> dismissRejectedOperation(String opId) async {
    final db = await _appDatabase.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'sync_operations',
        where: 'op_id = ?',
        whereArgs: [opId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Sync operation not found: $opId');
      }
      final operation = SyncOperation.fromMap(rows.single);
      if (operation.state != 'rejected') {
        throw StateError('Sync operation $opId is not rejected');
      }
      if (operation.type == 'create') {
        await _dismissRejectedCreate(txn, operation);
        return;
      }

      final deleted = await txn.delete(
        'sync_operations',
        where: 'op_id = ? AND state = ?',
        whereArgs: [operation.opId, 'rejected'],
      );
      if (deleted != 1) {
        throw StateError('Sync operation not found: $opId');
      }
      await unblockNextDependent(
        txn,
        householdId: operation.householdId,
        seq: operation.seq,
      );
      await reconcileBlockedOperationsOn(txn);
    });
  }

  Future<void> _saveAndBlockLater(SyncOperation operation) async {
    final db = await _appDatabase.database;
    await db.transaction((txn) async {
      final updated = await txn.update(
        'sync_operations',
        operation.toMap(),
        where: 'op_id = ?',
        whereArgs: [operation.opId],
      );
      if (updated == 0) {
        throw StateError('Sync operation not found: ${operation.opId}');
      }
      await txn.update(
        'sync_operations',
        const {'state': 'blocked'},
        where:
            'household_id = ? AND seq > ? AND '
            "state NOT IN ('completed', 'parked', 'rejected')",
        whereArgs: [operation.householdId, operation.seq],
      );
    });
  }

  Future<void> _dismissRejectedCreate(
    DatabaseExecutor txn,
    SyncOperation operation,
  ) async {
    final householdRows = await txn.query(
      'households',
      columns: ['server_id'],
      where: 'id = ?',
      whereArgs: [operation.householdId],
      limit: 1,
    );
    final serverId = householdRows.isEmpty
        ? null
        : householdRows.single['server_id'] as String?;
    final hasServerId = serverId != null && serverId.isNotEmpty;
    if (householdRows.isNotEmpty && !hasServerId) {
      final deleted = await txn.delete(
        'households',
        where: 'id = ?',
        whereArgs: [operation.householdId],
      );
      if (deleted != 1) {
        throw StateError('Household not found: ${operation.householdId}');
      }
      return;
    }

    final deleted = await txn.delete(
      'sync_operations',
      where: 'household_id = ? AND seq >= ?',
      whereArgs: [operation.householdId, operation.seq],
    );
    if (deleted == 0) {
      throw StateError('Sync operation not found: ${operation.opId}');
    }
  }

  /// Saves [operation] as completed and, when the next dependent operation
  /// is blocked, changes only that operation to pending.
  Future<void> completeOperation(SyncOperation operation) async {
    final db = await _appDatabase.database;
    await db.transaction((txn) async {
      final updated = await txn.update(
        'sync_operations',
        operation.toMap(),
        where: 'op_id = ?',
        whereArgs: [operation.opId],
      );
      if (updated == 0) {
        throw StateError('Sync operation not found: ${operation.opId}');
      }
      await unblockNextDependent(
        txn,
        householdId: operation.householdId,
        seq: operation.seq,
      );
    });
  }

  static Future<void> unblockNextDependent(
    DatabaseExecutor executor, {
    required String householdId,
    required int seq,
  }) async {
    final rows = await executor.query(
      'sync_operations',
      columns: ['op_id', 'state'],
      where: 'household_id = ? AND seq > ?',
      whereArgs: [householdId, seq],
      orderBy: 'seq ASC',
    );
    for (final row in rows) {
      final state = row['state'] as String;
      if (state == 'completed') {
        continue;
      }
      if (state == 'blocked') {
        await executor.update(
          'sync_operations',
          const {'state': 'pending'},
          where: 'op_id = ?',
          whereArgs: [row['op_id']],
        );
      }
      return;
    }
  }

  /// Marks operations that already sit behind a parked or rejected operation
  /// as blocked.
  ///
  /// Only `pending` and `retrying` rows with a higher sequence are changed.
  /// Completed, parked, rejected, and blocked rows, and every other household,
  /// stay as they are.
  Future<void> reconcileBlockedOperations() async {
    final db = await _appDatabase.database;
    await reconcileBlockedOperationsOn(db);
  }

  static Future<void> reconcileBlockedOperationsOn(DatabaseExecutor executor) {
    return executor.rawUpdate('''
      UPDATE sync_operations
      SET state = 'blocked'
      WHERE state IN ('pending', 'retrying')
        AND EXISTS (
          SELECT 1 FROM sync_operations AS earlier
          WHERE earlier.household_id = sync_operations.household_id
            AND earlier.state IN ('parked', 'rejected')
            AND earlier.seq < sync_operations.seq
        )
    ''');
  }

  Future<List<SyncOperation>> getBlockedOperations(String householdId) async {
    final db = await _appDatabase.database;

    final results = await db.query(
      'sync_operations',
      where: "household_id = ? AND state = 'blocked'",
      whereArgs: [householdId],
      orderBy: 'seq ASC',
    );

    return results.map(SyncOperation.fromMap).toList();
  }
}
