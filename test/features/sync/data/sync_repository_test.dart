import 'package:egov_household_survey/core/database/app_database.dart';
import 'package:egov_household_survey/features/households/domain/household.dart';
import 'package:egov_household_survey/features/sync/data/sync_repository.dart';
import 'package:egov_household_survey/features/sync/domain/sync_operation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database database;
  late SyncRepository repository;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: AppDatabase.onConfigure,
        onCreate: AppDatabase.onCreate,
      ),
    );
    repository = SyncRepository(appDatabase: AppDatabase.forTesting(database));
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'returns every operation ordered by creation time and sequence',
    () async {
      await _insertHousehold(database, 'hh-a');
      await _insertHousehold(database, 'hh-b');
      await _insertOperation(
        database,
        _operation(
          opId: 'later-higher-seq',
          householdId: 'hh-a',
          seq: 2,
          createdAt: DateTime.utc(2026, 11, 27, 10, 2),
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'same-time-lower-seq',
          householdId: 'hh-a',
          seq: 1,
          createdAt: DateTime.utc(2026, 11, 27, 10, 2),
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'earliest',
          householdId: 'hh-b',
          seq: 3,
          createdAt: DateTime.utc(2026, 11, 27, 10),
        ),
      );

      final operations = await repository.getAllOperations();

      expect(operations.map((operation) => operation.opId), [
        'earliest',
        'same-time-lower-seq',
        'later-higher-seq',
      ]);
    },
  );

  test('returns a household operations in sequence order', () async {
    await _insertHousehold(database, 'hh-a');
    await _insertHousehold(database, 'hh-b');
    await _insertOperation(
      database,
      _operation(opId: 'seq-3', householdId: 'hh-a', seq: 3),
    );
    await _insertOperation(
      database,
      _operation(opId: 'seq-1', householdId: 'hh-a', seq: 1),
    );
    await _insertOperation(
      database,
      _operation(opId: 'other', householdId: 'hh-b', seq: 1),
    );
    await _insertOperation(
      database,
      _operation(opId: 'seq-2', householdId: 'hh-a', seq: 2),
    );

    final operations = await repository.getOperationsForHousehold('hh-a');

    expect(operations.map((operation) => operation.seq), [1, 2, 3]);
  });

  test(
    'returns empty results when the queue has no matching operations',
    () async {
      expect(await repository.getAllOperations(), isEmpty);
      expect(await repository.getAllPendingOperations(), isEmpty);
      expect(await repository.getOperationsForHousehold('missing'), isEmpty);
      expect(await repository.getNextOperationForHousehold('missing'), isNull);
      expect(await repository.getBlockedOperations('missing'), isEmpty);
    },
  );

  test('pending reads include pending and retrying operations', () async {
    await _insertHousehold(database, 'hh-a');
    await _insertOperation(
      database,
      _operation(opId: 'done', householdId: 'hh-a', state: 'completed'),
    );
    await _insertOperation(
      database,
      _operation(
        opId: 'waiting',
        householdId: 'hh-a',
        seq: 2,
        state: 'blocked',
      ),
    );
    await _insertOperation(
      database,
      _operation(
        opId: 'again',
        householdId: 'hh-a',
        seq: 3,
        state: 'retrying',
        createdAt: DateTime.utc(2026, 11, 27, 10),
      ),
    );
    await _insertOperation(
      database,
      _operation(
        opId: 'first',
        householdId: 'hh-a',
        seq: 4,
        state: 'pending',
        createdAt: DateTime.utc(2026, 11, 27, 11),
      ),
    );

    final pending = await repository.getAllPendingOperations();

    expect(pending.map((operation) => operation.opId), ['again', 'first']);
  });

  test('updates retry metadata on the existing operation', () async {
    await _insertHousehold(database, 'hh-a');
    final original = _operation(opId: 'op-1', householdId: 'hh-a');
    await _insertOperation(database, original);
    final nextRetryAt = DateTime.utc(2026, 11, 27, 12, 4);

    await repository.updateOperation(
      SyncOperation(
        opId: original.opId,
        householdId: original.householdId,
        recordId: 'hh-0001',
        type: original.type,
        seq: original.seq,
        payload: original.payload,
        state: 'retrying',
        attemptCount: 2,
        nextRetryAt: nextRetryAt,
        lastError: 'timed out',
        createdAt: original.createdAt,
      ),
    );

    final saved = (await repository.getOperationsForHousehold('hh-a')).single;
    expect(saved.state, 'retrying');
    expect(saved.attemptCount, 2);
    expect(saved.nextRetryAt, nextRetryAt);
    expect(saved.lastError, 'timed out');
    expect(saved.recordId, 'hh-0001');
    expect(await repository.getAllOperations(), hasLength(1));
  });

  test('update throws when the operation does not exist', () async {
    await expectLater(
      repository.updateOperation(
        _operation(opId: 'missing', householdId: 'hh-a'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('returns the earliest unresolved operation for a household', () async {
    await _insertHousehold(database, 'hh-a');
    await _insertHousehold(database, 'hh-b');
    await _insertOperation(
      database,
      _operation(opId: 'done', householdId: 'hh-a', seq: 1, state: 'completed'),
    );
    await _insertOperation(
      database,
      _operation(opId: 'next', householdId: 'hh-a', seq: 2, state: 'retrying'),
    );
    await _insertOperation(
      database,
      _operation(opId: 'later', householdId: 'hh-a', seq: 3, state: 'pending'),
    );
    await _insertOperation(
      database,
      _operation(opId: 'other', householdId: 'hh-b', seq: 1),
    );

    final next = await repository.getNextOperationForHousehold('hh-a');

    expect(next, isNotNull);
    expect(next!.opId, 'next');
    expect(next.state, 'retrying');
  });

  test('returns null when every household operation is completed', () async {
    await _insertHousehold(database, 'hh-a');
    await _insertOperation(
      database,
      _operation(opId: 'done', householdId: 'hh-a', state: 'completed'),
    );

    expect(await repository.getNextOperationForHousehold('hh-a'), isNull);
  });

  test(
    'returns blocked operations for one household in sequence order',
    () async {
      await _insertHousehold(database, 'hh-a');
      await _insertHousehold(database, 'hh-b');
      await _insertOperation(
        database,
        _operation(
          opId: 'blocked-2',
          householdId: 'hh-a',
          seq: 2,
          state: 'blocked',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'pending',
          householdId: 'hh-a',
          seq: 3,
          state: 'pending',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'blocked-1',
          householdId: 'hh-a',
          seq: 1,
          state: 'blocked',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'other-blocked',
          householdId: 'hh-b',
          state: 'blocked',
        ),
      );

      final blocked = await repository.getBlockedOperations('hh-a');

      expect(blocked.map((operation) => operation.opId), [
        'blocked-1',
        'blocked-2',
      ]);
    },
  );

  test('saves the complete retry state of an existing operation', () async {
    await _insertHousehold(database, 'hh-a');
    final original = _operation(opId: 'op-1', householdId: 'hh-a');
    await _insertOperation(database, original);
    final nextRetryAt = DateTime.utc(2026, 11, 27, 12, 4);
    final savedOperation = SyncOperation(
      opId: original.opId,
      householdId: original.householdId,
      recordId: 'hh-0001',
      type: original.type,
      seq: original.seq,
      payload: original.payload,
      state: 'retrying',
      attemptCount: 3,
      nextRetryAt: nextRetryAt,
      lastError: 'service unavailable',
      createdAt: original.createdAt,
    );

    await repository.saveRetryState(savedOperation);

    final saved = (await repository.getOperationsForHousehold('hh-a')).single;
    expect(saved.state, 'retrying');
    expect(saved.attemptCount, 3);
    expect(saved.nextRetryAt, nextRetryAt);
    expect(saved.lastError, 'service unavailable');
    expect(saved.recordId, 'hh-0001');
    expect(saved.payload, original.payload);
    expect(await repository.getAllOperations(), hasLength(1));
  });

  test('saveRetryState throws when the operation does not exist', () async {
    await expectLater(
      repository.saveRetryState(
        _operation(opId: 'missing', householdId: 'hh-a'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'returns pending operations and due retries in creation and sequence order',
    () async {
      await _insertHousehold(database, 'hh-a');
      final now = DateTime.utc(2026, 11, 27, 12);
      await _insertOperation(
        database,
        _operation(
          opId: 'due-higher-seq',
          householdId: 'hh-a',
          seq: 2,
          state: 'retrying',
          attemptCount: 1,
          nextRetryAt: now,
          createdAt: DateTime.utc(2026, 11, 27, 10),
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'due-lower-seq',
          householdId: 'hh-a',
          seq: 1,
          state: 'retrying',
          attemptCount: 2,
          nextRetryAt: DateTime.utc(2026, 11, 27, 11),
          createdAt: DateTime.utc(2026, 11, 27, 10),
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'pending-early',
          householdId: 'hh-a',
          seq: 9,
          state: 'pending',
          createdAt: DateTime.utc(2026, 11, 27, 9),
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'pending-late',
          householdId: 'hh-a',
          seq: 1,
          state: 'pending',
          createdAt: DateTime.utc(2026, 11, 27, 11),
        ),
      );

      final ready = await repository.getReadyOperations(now: now);

      expect(ready.map((operation) => operation.opId), [
        'pending-early',
        'due-lower-seq',
        'due-higher-seq',
        'pending-late',
      ]);
    },
  );

  test('excludes retrying operations that are not due yet', () async {
    await _insertHousehold(database, 'hh-a');
    final now = DateTime.utc(2026, 11, 27, 12);
    await _insertOperation(
      database,
      _operation(
        opId: 'future',
        householdId: 'hh-a',
        state: 'retrying',
        attemptCount: 1,
        nextRetryAt: DateTime.utc(2026, 11, 27, 12, 1),
        createdAt: DateTime.utc(2026, 11, 27, 9),
      ),
    );
    await _insertOperation(
      database,
      _operation(
        opId: 'ready',
        householdId: 'hh-a',
        seq: 2,
        state: 'pending',
        createdAt: DateTime.utc(2026, 11, 27, 10),
      ),
    );

    final ready = await repository.getReadyOperations(now: now);

    expect(ready.map((operation) => operation.opId), ['ready']);
    expect(
      (await repository.getAllPendingOperations()).map(
        (operation) => operation.opId,
      ),
      ['future', 'ready'],
    );
  });

  test(
    'excludes parked, blocked, completed, and retrying operations without a due time',
    () async {
      await _insertHousehold(database, 'hh-a');
      final now = DateTime.utc(2026, 11, 27, 12);
      await _insertOperation(
        database,
        _operation(opId: 'parked', householdId: 'hh-a', state: 'parked'),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'blocked',
          householdId: 'hh-a',
          seq: 2,
          state: 'blocked',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'completed',
          householdId: 'hh-a',
          seq: 3,
          state: 'completed',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'retry-without-time',
          householdId: 'hh-a',
          seq: 4,
          state: 'retrying',
          attemptCount: 1,
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'pending',
          householdId: 'hh-a',
          seq: 5,
          state: 'pending',
        ),
      );

      final ready = await repository.getReadyOperations(now: now);

      expect(ready.map((operation) => operation.opId), ['pending']);
    },
  );

  test(
    'reconciles later pending operations that already sit behind a parked operation',
    () async {
      await _insertHousehold(database, 'hh-a');
      await _insertHousehold(database, 'hh-b');
      final earlier = _operation(
        opId: 'before-parked',
        householdId: 'hh-a',
        seq: 1,
        state: 'pending',
        createdAt: DateTime.utc(2026, 11, 27, 10),
      );
      final parked = _operation(
        opId: 'parked',
        householdId: 'hh-a',
        type: 'create',
        seq: 2,
        state: 'parked',
        attemptCount: 5,
        lastError: 'rejected',
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      );
      final nextRetryAt = DateTime.utc(2026, 11, 27, 12);
      final behind = _operation(
        opId: 'behind',
        householdId: 'hh-a',
        type: 'update',
        seq: 3,
        state: 'pending',
        attemptCount: 2,
        nextRetryAt: nextRetryAt,
        lastError: 'timed out',
        createdAt: DateTime.utc(2026, 11, 27, 10, 2),
      );
      final completed = _operation(
        opId: 'done',
        householdId: 'hh-a',
        seq: 4,
        state: 'completed',
        createdAt: DateTime.utc(2026, 11, 27, 10, 3),
      );
      final other = _operation(
        opId: 'other',
        householdId: 'hh-b',
        state: 'pending',
        createdAt: DateTime.utc(2026, 11, 27, 10, 4),
      );
      for (final operation in [earlier, parked, behind, completed, other]) {
        await _insertOperation(database, operation);
      }

      await repository.reconcileBlockedOperations();

      final saved = await repository.getOperationsForHousehold('hh-a');
      expect(saved.map((operation) => operation.state), [
        'pending',
        'parked',
        'blocked',
        'completed',
      ]);
      expect(saved[1].attemptCount, 5);
      expect(saved[1].lastError, 'rejected');
      expect(saved[1].payload, parked.payload);
      expect(saved[2].opId, 'behind');
      expect(saved[2].seq, 3);
      expect(saved[2].type, 'update');
      expect(saved[2].attemptCount, 2);
      expect(saved[2].nextRetryAt, nextRetryAt);
      expect(saved[2].lastError, 'timed out');
      expect(saved[2].payload, behind.payload);
      expect(saved[2].createdAt, behind.createdAt);
      final otherSaved = (await repository.getOperationsForHousehold(
        'hh-b',
      )).single;
      expect(otherSaved.state, 'pending');
      expect(otherSaved.payload, other.payload);
    },
  );

  test(
    'retrying a parked operation keeps its identity and later blocked operations',
    () async {
      await _insertHousehold(database, 'hh-a', serverId: 'hh-0004');
      await _insertHousehold(database, 'hh-b');
      final createdAt = DateTime.utc(2026, 11, 27, 10);
      final nextRetryAt = DateTime.utc(2026, 11, 27, 12);
      final parked = _operation(
        opId: 'op-parked',
        householdId: 'hh-a',
        type: 'update',
        seq: 2,
        recordId: 'hh-0004',
        state: 'parked',
        attemptCount: 5,
        nextRetryAt: nextRetryAt,
        lastError: 'limit exhausted',
        createdAt: createdAt,
      );
      final blocked = _operation(
        opId: 'op-later',
        householdId: 'hh-a',
        type: 'update',
        seq: 3,
        recordId: 'hh-0004',
        state: 'blocked',
        attemptCount: 2,
        lastError: 'waiting',
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      );
      final other = _operation(
        opId: 'op-other',
        householdId: 'hh-b',
        state: 'pending',
      );
      await _insertOperation(database, parked);
      await _insertOperation(database, blocked);
      await _insertOperation(database, other);

      await repository.retryParkedOperation(parked.opId);

      final saved = await repository.getOperationsForHousehold('hh-a');
      expect(saved.first.opId, parked.opId);
      expect(saved.first.householdId, 'hh-a');
      expect(saved.first.recordId, 'hh-0004');
      expect(saved.first.seq, 2);
      expect(saved.first.type, 'update');
      expect(saved.first.payload, parked.payload);
      expect(saved.first.createdAt, createdAt);
      expect(saved.first.state, 'pending');
      expect(saved.first.attemptCount, 0);
      expect(saved.first.nextRetryAt, isNull);
      expect(saved.first.lastError, isNull);
      expect(saved.last.state, 'blocked');
      expect(saved.last.payload, blocked.payload);
      expect(saved.last.attemptCount, 2);
      expect(
        (await repository.getOperationsForHousehold('hh-b')).single.state,
        'pending',
      );
    },
  );

  test('retry refuses an operation that is not parked', () async {
    await _insertHousehold(database, 'hh-a');
    await _insertOperation(
      database,
      _operation(
        opId: 'op-rejected',
        householdId: 'hh-a',
        state: 'rejected',
        lastError: 'permanent',
      ),
    );

    await expectLater(
      repository.retryParkedOperation('op-rejected'),
      throwsA(isA<StateError>()),
    );
    expect(
      (await repository.getOperationsForHousehold('hh-a')).single.state,
      'rejected',
    );
  });

  test(
    'dismissing a rejected update releases the next operation only',
    () async {
      await _insertHousehold(database, 'hh-a', serverId: 'hh-0004');
      await _insertHousehold(database, 'hh-b');
      final rejected = _operation(
        opId: 'op-rejected',
        householdId: 'hh-a',
        type: 'update',
        seq: 2,
        recordId: 'hh-0004',
        state: 'rejected',
        lastError: 'invalid name',
      );
      final next = _operation(
        opId: 'op-next',
        householdId: 'hh-a',
        type: 'update',
        seq: 3,
        recordId: 'hh-0004',
        state: 'blocked',
      );
      final after = _operation(
        opId: 'op-after',
        householdId: 'hh-a',
        type: 'update',
        seq: 4,
        recordId: 'hh-0004',
        state: 'blocked',
      );
      final other = _operation(
        opId: 'op-other',
        householdId: 'hh-b',
        state: 'pending',
      );
      for (final operation in [rejected, next, after, other]) {
        await _insertOperation(database, operation);
      }

      await repository.dismissRejectedOperation(rejected.opId);

      final saved = await repository.getOperationsForHousehold('hh-a');
      expect(saved.map((operation) => operation.opId), ['op-next', 'op-after']);
      expect(saved.map((operation) => operation.state), ['pending', 'blocked']);
      expect(saved.first.payload, next.payload);
      expect(saved.first.recordId, 'hh-0004');
      final household = await database.query(
        'households',
        where: 'id = ?',
        whereArgs: ['hh-a'],
      );
      expect(household.single['head_name'], 'Asha Noor');
      expect(household.single['server_id'], 'hh-0004');
      expect(
        (await repository.getOperationsForHousehold('hh-b')).single.opId,
        'op-other',
      );
    },
  );

  test(
    'dismissing a rejected create removes the unsynced household and its operations',
    () async {
      await _insertHousehold(database, 'hh-local');
      await _insertHousehold(database, 'hh-other', serverId: 'hh-0009');
      await _insertOperation(
        database,
        _operation(
          opId: 'op-create',
          householdId: 'hh-local',
          state: 'rejected',
          lastError: 'settlement is empty',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-update',
          householdId: 'hh-local',
          type: 'update',
          seq: 2,
          state: 'blocked',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-other',
          householdId: 'hh-other',
          type: 'update',
          recordId: 'hh-0009',
          state: 'pending',
        ),
      );

      await repository.dismissRejectedOperation('op-create');

      expect(
        await database.query(
          'households',
          where: 'id = ?',
          whereArgs: ['hh-local'],
        ),
        isEmpty,
      );
      expect(await repository.getOperationsForHousehold('hh-local'), isEmpty);
      final otherHousehold = await database.query(
        'households',
        where: 'id = ?',
        whereArgs: ['hh-other'],
      );
      expect(otherHousehold, hasLength(1));
      expect(
        (await repository.getOperationsForHousehold('hh-other')).single.opId,
        'op-other',
      );
    },
  );

  test(
    'dismissing a rejected create keeps a household that already has a server id',
    () async {
      await _insertHousehold(database, 'hh-a', serverId: 'hh-0004');
      await _insertOperation(
        database,
        _operation(
          opId: 'op-done',
          householdId: 'hh-a',
          seq: 1,
          state: 'completed',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-create',
          householdId: 'hh-a',
          seq: 2,
          state: 'rejected',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-update',
          householdId: 'hh-a',
          type: 'update',
          seq: 3,
          state: 'blocked',
        ),
      );

      await repository.dismissRejectedOperation('op-create');

      final household = await database.query(
        'households',
        where: 'id = ?',
        whereArgs: ['hh-a'],
      );
      expect(household.single['server_id'], 'hh-0004');
      final saved = await repository.getOperationsForHousehold('hh-a');
      expect(saved.map((operation) => operation.opId), ['op-done']);
      expect(saved.single.state, 'completed');
    },
  );

  test(
    'dismissing a rejected update keeps the next operation blocked while an earlier one is parked',
    () async {
      await _insertHousehold(database, 'hh-a', serverId: 'hh-0004');
      await _insertOperation(
        database,
        _operation(
          opId: 'op-parked',
          householdId: 'hh-a',
          seq: 1,
          state: 'parked',
          lastError: 'limit exhausted',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-rejected',
          householdId: 'hh-a',
          type: 'update',
          seq: 2,
          state: 'rejected',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-later',
          householdId: 'hh-a',
          type: 'update',
          seq: 3,
          state: 'blocked',
        ),
      );

      await repository.dismissRejectedOperation('op-rejected');

      final saved = await repository.getOperationsForHousehold('hh-a');
      expect(saved.map((operation) => operation.opId), [
        'op-parked',
        'op-later',
      ]);
      expect(saved.map((operation) => operation.state), ['parked', 'blocked']);
      expect(saved.first.lastError, 'limit exhausted');
    },
  );

  test('dismiss refuses a parked operation', () async {
    await _insertHousehold(database, 'hh-a');
    await _insertOperation(
      database,
      _operation(
        opId: 'op-parked',
        householdId: 'hh-a',
        state: 'parked',
        lastError: 'limit exhausted',
      ),
    );

    await expectLater(
      repository.dismissRejectedOperation('op-parked'),
      throwsA(isA<StateError>()),
    );
    expect(
      (await repository.getOperationsForHousehold('hh-a')).single.state,
      'parked',
    );
  });

  test(
    'reconciles later pending operations that sit behind a rejected operation',
    () async {
      await _insertHousehold(database, 'hh-a');
      await _insertHousehold(database, 'hh-b');
      await _insertOperation(
        database,
        _operation(
          opId: 'rejected',
          householdId: 'hh-a',
          state: 'rejected',
          lastError: 'permanent',
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'behind',
          householdId: 'hh-a',
          type: 'update',
          seq: 2,
          state: 'pending',
        ),
      );
      await _insertOperation(
        database,
        _operation(opId: 'other', householdId: 'hh-b', state: 'pending'),
      );

      await repository.reconcileBlockedOperations();

      final saved = await repository.getOperationsForHousehold('hh-a');
      expect(saved.map((operation) => operation.state), [
        'rejected',
        'blocked',
      ]);
      expect(saved.first.lastError, 'permanent');
      expect(
        (await repository.getOperationsForHousehold('hh-b')).single.state,
        'pending',
      );
    },
  );
}

Future<void> _insertHousehold(
  Database database,
  String id, {
  String? serverId,
}) {
  final createdAt = DateTime.utc(2026, 11, 26, 9);
  return database.insert(
    'households',
    Household(
      id: id,
      serverId: serverId,
      headName: 'Asha Noor',
      memberCount: 4,
      settlement: 'Kibera North',
      createdAt: createdAt,
      updatedAt: createdAt,
    ).toMap(),
  );
}

Future<void> _insertOperation(Database database, SyncOperation operation) {
  return database.insert('sync_operations', operation.toMap());
}

SyncOperation _operation({
  required String opId,
  required String householdId,
  String type = 'create',
  int seq = 1,
  String? recordId,
  String state = 'pending',
  int attemptCount = 0,
  DateTime? nextRetryAt,
  String? lastError,
  DateTime? createdAt,
}) {
  return SyncOperation(
    opId: opId,
    householdId: householdId,
    recordId: recordId,
    type: type,
    seq: seq,
    payload: const {
      'head_name': 'Asha Noor',
      'member_count': 4,
      'settlement': 'Kibera North',
    },
    state: state,
    attemptCount: attemptCount,
    nextRetryAt: nextRetryAt,
    lastError: lastError,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 27, 10, 1),
  );
}
