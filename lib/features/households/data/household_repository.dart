import 'package:sqflite/sqflite.dart';

import '../../../core/database/app_database.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/api_service.dart';
import '../domain/household.dart';
import '../../sync/data/sync_repository.dart';
import '../../sync/domain/sync_operation.dart';

/// The returned server ID is already stored on a different local household.
class ServerIdMappingConflictException implements Exception {
  const ServerIdMappingConflictException({
    required this.serverId,
    required this.householdId,
    required this.existingHouseholdId,
  });

  final String serverId;
  final String householdId;
  final String existingHouseholdId;

  @override
  String toString() {
    return 'ServerIdMappingConflictException: server ID $serverId already '
        'belongs to household $existingHouseholdId and cannot be mapped to '
        '$householdId';
  }
}

class HouseholdRepository {
  final AppDatabase _appDatabase;
  final ApiService _apiService;

  // Dependency injection for the database instance
  HouseholdRepository({
    AppDatabase? appDatabase,
    ApiService? apiService,
    AppLogger? logger,
  }) : _appDatabase = appDatabase ?? AppDatabase.instance,
       _apiService = apiService ?? ApiService(baseUrl: defaultBaseUrl),
       _logger = logger ?? AppLogger();

  static const String defaultBaseUrl = 'http://127.0.0.1:8080';
  final AppLogger _logger;

  Future<void> createHousehold(Household household) async {
    final db = await _appDatabase.database;

    await db.insert(
      'households',
      household.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<List<Household>> getHouseholds() async {
    final db = await _appDatabase.database;

    final results = await db.query('households', orderBy: 'updated_at DESC');

    return results.map(Household.fromMap).toList();
  }

  Future<void> fetchInitialHouseholds() async {
    final households = await _apiService.fetchHouseholds();
    final db = await _appDatabase.database;

    await db.transaction((txn) async {
      for (final household in households) {
        final existing = await txn.query(
          'households',
          columns: ['id'],
          where: 'id = ? OR server_id = ?',
          whereArgs: [household.id, household.id],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          continue;
        }

        await txn.insert(
          'households',
          household.toMap(),
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
    });
  }

  Future<Household?> getHouseholdById(String id) async {
    final db = await _appDatabase.database;

    final results = await db.query(
      'households',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    if (results.isEmpty) {
      return null;
    }

    return Household.fromMap(results.first);
  }

  Future<void> updateHousehold(Household household) async {
    final db = await _appDatabase.database;

    final rowsUpdated = await db.update(
      'households',
      household.toMap(),
      where: 'id = ?',
      whereArgs: [household.id],
    );

    if (rowsUpdated == 0) {
      throw StateError('Household not found: ${household.id}');
    }
  }

  Future<void> updateHouseholdWithOperation({
    required String id,
    required String headName,
    required int memberCount,
    required String settlement,
    required String opId,
  }) async {
    final db = await _appDatabase.database;
    late Household existing;
    late int nextSeq;
    late String operationState;

    await db.transaction((txn) async {
      final rows = await txn.query(
        'households',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Household not found: $id');
      }

      existing = Household.fromMap(rows.first);
      final now = DateTime.now().toUtc();
      nextSeq = existing.lastSeq + 1;
      final updated = Household(
        id: existing.id,
        serverId: existing.serverId,
        headName: headName,
        memberCount: memberCount,
        settlement: settlement,
        lastSeq: nextSeq,
        createdAt: existing.createdAt,
        updatedAt: now,
      );

      await txn.update(
        'households',
        updated.toMap(),
        where: 'id = ?',
        whereArgs: [existing.id],
      );

      final parkedEarlier = await txn.query(
        'sync_operations',
        columns: ['op_id'],
        where:
            "household_id = ? AND state IN ('parked', 'rejected') AND seq < ?",
        whereArgs: [existing.id, nextSeq],
        limit: 1,
      );
      operationState = parkedEarlier.isEmpty ? 'pending' : 'blocked';

      await txn.insert(
        'sync_operations',
        SyncOperation(
          opId: opId,
          householdId: existing.id,
          recordId: existing.serverId,
          type: 'update',
          seq: nextSeq,
          payload: _changedFields(
            existing: existing,
            headName: headName,
            memberCount: memberCount,
            settlement: settlement,
          ),
          state: operationState,
          createdAt: now,
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    });

    final pending = await _pendingCount(id);
    _logger.info(
      LogCategory.household,
      '[LOCAL UPDATE]\n'
      'type=UPDATE\n'
      'seq=$nextSeq\n'
      'state=$operationState\n'
      'server=${existing.serverId ?? 'none'}\n'
      'queued locally and not sent to the server\n'
      '${_changeLines(existing: existing, headName: headName, memberCount: memberCount, settlement: settlement)}\n'
      '[QUEUE: $pending pending for household]',
      operationId: opId,
      householdId: existing.id,
      serverId: existing.serverId,
    );
  }

  String _changeLines({
    required Household existing,
    required String headName,
    required int memberCount,
    required String settlement,
  }) {
    final changes = <String>[];
    if (headName != existing.headName) {
      changes.add('head_name: ${existing.headName} -> $headName');
    }
    if (memberCount != existing.memberCount) {
      changes.add('member_count: ${existing.memberCount} -> $memberCount');
    }
    if (settlement != existing.settlement) {
      changes.add('settlement: ${existing.settlement} -> $settlement');
    }
    if (changes.isEmpty) {
      return 'changed fields: none';
    }
    return changes.join('\n');
  }

  Future<int> _pendingCount(String householdId) async {
    final db = await _appDatabase.database;
    final rows = await db.query(
      'sync_operations',
      columns: ['op_id'],
      where: "household_id = ? AND state IN ('pending', 'retrying')",
      whereArgs: [householdId],
    );
    return rows.length;
  }

  Map<String, dynamic> _changedFields({
    required Household existing,
    required String headName,
    required int memberCount,
    required String settlement,
  }) {
    final payload = <String, dynamic>{};
    if (headName != existing.headName) {
      payload['head_name'] = headName;
    }
    if (memberCount != existing.memberCount) {
      payload['member_count'] = memberCount;
    }
    if (settlement != existing.settlement) {
      payload['settlement'] = settlement;
    }
    return payload;
  }

  Future<void> createHouseholdWithOperation(
    Household household,
    SyncOperation operation,
  ) async {
    final db = await _appDatabase.database;

    await db.transaction((txn) async {
      await txn.insert(
        'households',
        household.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

      await txn.insert(
        'sync_operations',
        operation.toMap(),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    });

    final pending = await _pendingCount(household.id);
    _logger.info(
      LogCategory.household,
      '[LOCAL CREATE]\n'
      'type=CREATE\n'
      'seq=${operation.seq}\n'
      'state=${operation.state}\n'
      'server=${household.serverId ?? 'none'}\n'
      'queued locally and not sent to the server\n'
      '[QUEUE: $pending pending for household]',
      operationId: operation.opId,
      householdId: household.id,
      serverId: household.serverId,
    );
  }

  Future<void> completeCreateOperation({
    required String opId,
    required String householdId,
    required String serverId,
  }) async {
    _logger.info(
      LogCategory.household,
      'Create server ID mapping started',
      operationId: opId,
      householdId: householdId,
      serverId: serverId,
    );
    final db = await _appDatabase.database;

    var laterUpdated = 0;
    try {
      await db.transaction((txn) async {
        final operationRows = await txn.query(
          'sync_operations',
          where: 'op_id = ?',
          whereArgs: [opId],
          limit: 1,
        );
        if (operationRows.isEmpty) {
          throw StateError('Sync operation not found: $opId');
        }

        final operation = SyncOperation.fromMap(operationRows.first);
        if (operation.householdId != householdId) {
          throw StateError(
            'Sync operation $opId does not belong to household $householdId',
          );
        }
        if (operation.type != 'create') {
          throw StateError('Sync operation $opId is not a create operation');
        }

        final householdRows = await txn.query(
          'households',
          where: 'id = ?',
          whereArgs: [householdId],
          limit: 1,
        );
        if (householdRows.isEmpty) {
          throw StateError('Household not found: $householdId');
        }

        final household = Household.fromMap(householdRows.first);
        if (household.serverId != null && household.serverId != serverId) {
          throw StateError(
            'Household $householdId is already mapped to ${household.serverId}',
          );
        }

        final ownerRows = await txn.query(
          'households',
          columns: ['id'],
          where: 'server_id = ? AND id != ?',
          whereArgs: [serverId, householdId],
          limit: 1,
        );
        if (ownerRows.isNotEmpty) {
          throw ServerIdMappingConflictException(
            serverId: serverId,
            householdId: householdId,
            existingHouseholdId: ownerRows.single['id'] as String,
          );
        }

        laterUpdated = await txn.update(
          'sync_operations',
          {'record_id': serverId},
          where: 'household_id = ? AND op_id != ?',
          whereArgs: [householdId, opId],
        );

        final completed = await txn.update(
          'sync_operations',
          {'state': 'completed'},
          where: 'op_id = ?',
          whereArgs: [opId],
        );
        if (completed == 0) {
          throw StateError('Sync operation not found: $opId');
        }

        final mapped = await txn.update(
          'households',
          {'server_id': serverId},
          where: 'id = ?',
          whereArgs: [householdId],
        );
        if (mapped == 0) {
          throw StateError('Household not found: $householdId');
        }

        await SyncRepository.unblockNextDependent(
          txn,
          householdId: householdId,
          seq: operation.seq,
        );
      });
    } catch (error, stackTrace) {
      _logger.error(
        LogCategory.household,
        'Create server ID mapping failed',
        operationId: opId,
        householdId: householdId,
        serverId: serverId,
        error: error,
        stackTrace: stackTrace,
      );
      _logger.error(
        LogCategory.household,
        '[ID MAPPING: failed]\n'
        'local=$householdId\n'
        'server=$serverId',
        operationId: opId,
        householdId: householdId,
        serverId: serverId,
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }

    _logger.info(
      LogCategory.household,
      'Create server ID mapping completed',
      operationId: opId,
      householdId: householdId,
      serverId: serverId,
    );
    _logger.info(
      LogCategory.household,
      '[ID MAPPING: successful]\n'
      'local=$householdId\n'
      'server=$serverId\n'
      'later operations updated=$laterUpdated',
      operationId: opId,
      householdId: householdId,
      serverId: serverId,
    );
  }
}
