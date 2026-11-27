import 'package:egov_household_survey/core/database/app_database.dart';
import 'package:egov_household_survey/core/logging/app_logger.dart';
import 'package:egov_household_survey/core/network/api_service.dart';
import 'package:egov_household_survey/features/households/data/household_repository.dart';
import 'package:egov_household_survey/features/households/domain/household.dart';
import 'package:egov_household_survey/features/sync/data/sync_repository.dart';
import 'package:egov_household_survey/features/sync/domain/sync_operation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MockApiService extends Mock implements ApiService {}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database database;
  late _MockApiService apiService;
  late HouseholdRepository householdRepository;
  late SyncRepository syncRepository;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: AppDatabase.onConfigure,
        onCreate: AppDatabase.onCreate,
      ),
    );
    final appDatabase = AppDatabase.forTesting(database);
    apiService = _MockApiService();
    householdRepository = HouseholdRepository(
      appDatabase: appDatabase,
      apiService: apiService,
    );
    syncRepository = SyncRepository(appDatabase: appDatabase);
  });

  tearDown(() async {
    await database.close();
  });

  test('saves a household and its sync operation in one transaction', () async {
    final household = _household(id: 'hh-3f2a9c1b0e47');
    final operation = _operation(opId: 'op-1', householdId: household.id);

    await householdRepository.createHouseholdWithOperation(
      household,
      operation,
    );

    final savedHousehold = await householdRepository.getHouseholdById(
      household.id,
    );
    final savedOperations = await syncRepository.getOperationsForHousehold(
      household.id,
    );

    expect(savedHousehold, isNotNull);
    expect(savedHousehold!.id, household.id);
    expect(savedOperations, hasLength(1));
    expect(savedOperations.single.opId, operation.opId);
    expect(savedOperations.single.householdId, household.id);
  });

  test(
    'rolls back the household when the sync operation insert fails',
    () async {
      final existing = _household(id: 'hh-existing');
      final existingOperation = _operation(
        opId: 'op-existing',
        householdId: existing.id,
      );
      await householdRepository.createHouseholdWithOperation(
        existing,
        existingOperation,
      );

      final incoming = _household(id: 'hh-incoming');
      final conflictingOperation = _operation(
        opId: existingOperation.opId,
        householdId: incoming.id,
      );

      await expectLater(
        householdRepository.createHouseholdWithOperation(
          incoming,
          conflictingOperation,
        ),
        throwsA(isA<DatabaseException>()),
      );

      expect(await householdRepository.getHouseholdById(incoming.id), isNull);
      expect(
        await syncRepository.getOperationsForHousehold(incoming.id),
        isEmpty,
      );

      final savedExisting = await householdRepository.getHouseholdById(
        existing.id,
      );
      final savedOperations = await syncRepository.getOperationsForHousehold(
        existing.id,
      );
      expect(savedExisting, isNotNull);
      expect(savedExisting!.headName, existing.headName);
      expect(savedOperations, hasLength(1));
      expect(savedOperations.single.opId, existingOperation.opId);
    },
  );

  test('reads the saved household and operation back', () async {
    final createdAt = DateTime.utc(2026, 11, 26, 10);
    final updatedAt = DateTime.utc(2026, 11, 26, 11, 30);
    final household = _household(
      id: 'hh-0001',
      serverId: 'hh-0001',
      headName: 'Amina Wanjiru',
      memberCount: 4,
      settlement: 'Kibera North',
      lastSeq: 1,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
    final operation = _operation(
      opId: '6f1c2d0e-7b3a-4e1f-9c2a-0b6d8e4a1f77',
      householdId: household.id,
      type: 'update',
      seq: 1,
      payload: {
        'head_name': 'Amina Wanjiru',
        'member_count': 4,
        'settlement': 'Kibera North',
      },
      state: 'pending',
      attemptCount: 0,
      createdAt: createdAt,
    );

    await householdRepository.createHouseholdWithOperation(
      household,
      operation,
    );

    final savedHousehold = await householdRepository.getHouseholdById(
      household.id,
    );
    final savedOperations = await syncRepository.getOperationsForHousehold(
      household.id,
    );
    final pending = await syncRepository.getAllPendingOperations();

    expect(savedHousehold, isNotNull);
    expect(savedHousehold!.id, household.id);
    expect(savedHousehold.serverId, household.serverId);
    expect(savedHousehold.headName, household.headName);
    expect(savedHousehold.memberCount, household.memberCount);
    expect(savedHousehold.settlement, household.settlement);
    expect(savedHousehold.lastSeq, household.lastSeq);
    expect(savedHousehold.createdAt, household.createdAt);
    expect(savedHousehold.updatedAt, household.updatedAt);

    expect(savedOperations, hasLength(1));
    final savedOperation = savedOperations.single;
    expect(savedOperation.opId, operation.opId);
    expect(savedOperation.householdId, operation.householdId);
    expect(savedOperation.type, operation.type);
    expect(savedOperation.seq, operation.seq);
    expect(savedOperation.payload, operation.payload);
    expect(savedOperation.state, operation.state);
    expect(savedOperation.attemptCount, operation.attemptCount);
    expect(savedOperation.nextRetryAt, isNull);
    expect(savedOperation.lastError, isNull);
    expect(savedOperation.createdAt, operation.createdAt);

    expect(pending, hasLength(1));
    expect(pending.single.opId, operation.opId);
  });

  test('returns one household\'s operations ordered by sequence', () async {
    final first = _household(id: 'hh-first');
    final second = _household(id: 'hh-second', headName: 'Joseph Otieno');
    await householdRepository.createHousehold(first);
    await householdRepository.createHousehold(second);

    final firstOperations = [
      _operation(
        opId: 'op-first-3',
        householdId: first.id,
        type: 'update',
        seq: 3,
      ),
      _operation(
        opId: 'op-first-1',
        householdId: first.id,
        type: 'create',
        seq: 1,
      ),
      _operation(
        opId: 'op-first-2',
        householdId: first.id,
        type: 'update',
        seq: 2,
      ),
    ];
    final secondOperation = _operation(
      opId: 'op-second-1',
      householdId: second.id,
      seq: 1,
    );

    for (final operation in firstOperations) {
      await database.insert('sync_operations', operation.toMap());
    }
    await database.insert('sync_operations', secondOperation.toMap());

    final saved = await syncRepository.getOperationsForHousehold(first.id);

    expect(saved.map((operation) => operation.seq).toList(), [1, 2, 3]);
    expect(saved.map((operation) => operation.householdId).toSet(), {first.id});
    expect(
      saved.map((operation) => operation.opId),
      isNot(contains(secondOperation.opId)),
    );
  });

  test('saves a household update and its sync operation together', () async {
    final createdAt = DateTime.utc(2026, 11, 26, 9);
    final existing = _household(
      id: 'hh-local-1',
      headName: 'Asha Noor',
      memberCount: 4,
      settlement: 'Kibera North',
      lastSeq: 1,
      createdAt: createdAt,
    );
    await householdRepository.createHousehold(existing);

    await householdRepository.updateHouseholdWithOperation(
      id: existing.id,
      headName: 'Asha Noor',
      memberCount: 5,
      settlement: 'Kibera North',
      opId: 'op-update-1',
    );

    final saved = await householdRepository.getHouseholdById(existing.id);
    final operations = await syncRepository.getOperationsForHousehold(
      existing.id,
    );

    expect(saved, isNotNull);
    expect(saved!.id, existing.id);
    expect(saved.serverId, isNull);
    expect(saved.headName, 'Asha Noor');
    expect(saved.memberCount, 5);
    expect(saved.lastSeq, 2);
    expect(saved.createdAt, createdAt);
    expect(saved.updatedAt.isAfter(createdAt), isTrue);

    expect(operations, hasLength(1));
    expect(operations.single.type, 'update');
    expect(operations.single.householdId, existing.id);
    expect(operations.single.recordId, isNull);
    expect(operations.single.seq, 2);
  });

  test('an update behind a parked operation is saved as blocked', () async {
    final createdAt = DateTime.utc(2026, 11, 26, 9);
    final parkedHousehold = _household(
      id: 'local-parked',
      serverId: 'hh-0004',
      lastSeq: 1,
      createdAt: createdAt,
    );
    final other = _household(
      id: 'local-other',
      lastSeq: 1,
      createdAt: createdAt,
    );
    await householdRepository.createHousehold(parkedHousehold);
    await householdRepository.createHousehold(other);
    final parked = _operation(
      opId: 'op-parked',
      householdId: parkedHousehold.id,
      state: 'parked',
      attemptCount: 5,
      lastError: 'rejected',
      createdAt: createdAt,
    );
    final otherOperation = _operation(
      opId: 'op-other',
      householdId: other.id,
      createdAt: createdAt,
    );
    await database.insert('sync_operations', parked.toMap());
    await database.insert('sync_operations', otherOperation.toMap());

    await householdRepository.updateHouseholdWithOperation(
      id: parkedHousehold.id,
      headName: 'Asha Noor',
      memberCount: 6,
      settlement: 'Kibera North',
      opId: 'op-new',
    );
    await householdRepository.updateHouseholdWithOperation(
      id: other.id,
      headName: 'Other Name',
      memberCount: 4,
      settlement: 'Kibera North',
      opId: 'op-other-update',
    );

    final saved = await syncRepository.getOperationsForHousehold(
      parkedHousehold.id,
    );
    expect(saved.first.state, 'parked');
    expect(saved.first.attemptCount, 5);
    expect(saved.first.lastError, 'rejected');
    expect(saved.first.payload, parked.payload);
    expect(saved.first.seq, 1);
    expect(saved.last.opId, 'op-new');
    expect(saved.last.state, 'blocked');
    expect(saved.last.seq, 2);
    expect(saved.last.type, 'update');
    expect(saved.last.recordId, 'hh-0004');
    expect(saved.last.attemptCount, 0);
    expect(saved.last.nextRetryAt, isNull);
    expect(saved.last.payload, {'member_count': 6});

    final otherSaved = await syncRepository.getOperationsForHousehold(other.id);
    expect(otherSaved.map((operation) => operation.state), [
      'pending',
      'pending',
    ]);
    expect(otherSaved.last.opId, 'op-other-update');
  });

  test('an update behind a rejected operation is saved as blocked', () async {
    final createdAt = DateTime.utc(2026, 11, 26, 9);
    final household = _household(
      id: 'local-rejected',
      serverId: 'hh-0004',
      lastSeq: 1,
      createdAt: createdAt,
    );
    await householdRepository.createHousehold(household);
    await database.insert(
      'sync_operations',
      _operation(
        opId: 'op-rejected',
        householdId: household.id,
        state: 'rejected',
        lastError: 'head name is empty',
        createdAt: createdAt,
      ).toMap(),
    );

    await householdRepository.updateHouseholdWithOperation(
      id: household.id,
      headName: 'Asha Noor',
      memberCount: 6,
      settlement: 'Kibera North',
      opId: 'op-new',
    );

    final saved = await syncRepository.getOperationsForHousehold(household.id);
    expect(saved.map((operation) => operation.state), ['rejected', 'blocked']);
    expect(saved.last.opId, 'op-new');
    expect(saved.last.seq, 2);
    expect(saved.last.payload, {'member_count': 6});
    expect(saved.first.lastError, 'head name is empty');
  });

  test('logs local create and update before they are sent', () async {
    final logs = <LogEntry>[];
    final logged = HouseholdRepository(
      appDatabase: AppDatabase.forTesting(database),
      apiService: apiService,
      logger: AppLogger(
        clock: () => DateTime.utc(2026, 11, 27, 12),
        write: logs.add,
      ),
    );
    final household = _household(id: 'local-1');
    await logged.createHouseholdWithOperation(
      household,
      _operation(opId: 'op-create', householdId: household.id),
    );
    await logged.updateHouseholdWithOperation(
      id: household.id,
      headName: 'New Name',
      memberCount: 6,
      settlement: 'New Settlement',
      opId: 'op-update',
    );
    await logged.createHousehold(
      _household(id: 'synced', serverId: 'hh-0009', lastSeq: 3),
    );
    await logged.updateHouseholdWithOperation(
      id: 'synced',
      headName: 'Asha Noor',
      memberCount: 5,
      settlement: 'Kibera North',
      opId: 'op-synced',
    );

    expect(logs, hasLength(3));
    final created = logs[0];
    expect(created.operationId, 'op-create');
    expect(created.householdId, 'local-1');
    expect(created.serverId, isNull);
    expect(created.message, contains('[LOCAL CREATE]'));
    expect(created.message, contains('type=CREATE'));
    expect(created.message, contains('seq=1'));
    expect(created.message, contains('state=pending'));
    expect(created.message, contains('server=none'));
    expect(
      created.message,
      contains('queued locally and not sent to the server'),
    );
    expect(created.message, contains('[QUEUE: 1 pending for household]'));
    expect(created.message, isNot(contains('Sending')));

    final updated = logs[1];
    expect(updated.operationId, 'op-update');
    expect(updated.householdId, 'local-1');
    expect(updated.message, contains('[LOCAL UPDATE]'));
    expect(updated.message, contains('type=UPDATE'));
    expect(updated.message, contains('seq=2'));
    expect(updated.message, contains('state=pending'));
    expect(updated.message, contains('server=none'));
    expect(updated.message, contains('head_name: Asha Noor -> New Name'));
    expect(updated.message, contains('member_count: 4 -> 6'));
    expect(
      updated.message,
      contains('settlement: Kibera North -> New Settlement'),
    );
    expect(updated.message, contains('[QUEUE: 2 pending for household]'));
    expect(
      updated.message,
      contains('queued locally and not sent to the server'),
    );
    expect(updated.message, isNot(contains('Sending')));

    final synced = logs[2];
    expect(synced.operationId, 'op-synced');
    expect(synced.householdId, 'synced');
    expect(synced.serverId, 'hh-0009');
    expect(synced.message, contains('type=UPDATE'));
    expect(synced.message, contains('seq=4'));
    expect(synced.message, contains('server=hh-0009'));
    expect(synced.message, contains('member_count: 4 -> 5'));
    expect(synced.message, contains('[QUEUE: 1 pending for household]'));
    expect(synced.message, isNot(contains('head_name:')));
    expect(synced.message, isNot(contains('settlement:')));
  });

  test('editing before create sync keeps create then update order', () async {
    final household = _household(id: 'local-uuid', lastSeq: 1);
    await householdRepository.createHouseholdWithOperation(
      household,
      _operation(
        opId: 'op-create',
        householdId: household.id,
        type: 'create',
        seq: 1,
      ),
    );

    await householdRepository.updateHouseholdWithOperation(
      id: household.id,
      headName: 'Asha Noor Updated',
      memberCount: 5,
      settlement: household.settlement,
      opId: 'op-update',
    );

    final households = await householdRepository.getHouseholds();
    final operations = await syncRepository.getOperationsForHousehold(
      household.id,
    );

    expect(households, hasLength(1));
    expect(households.single.id, household.id);
    expect(households.single.serverId, isNull);
    expect(households.single.headName, 'Asha Noor Updated');
    expect(households.single.memberCount, 5);
    expect(operations.map((operation) => operation.type), ['create', 'update']);
    expect(operations.map((operation) => operation.seq), [1, 2]);
    expect(operations.map((operation) => operation.recordId), [null, null]);
    expect(operations.first.state, 'pending');
    expect(operations.last.householdId, household.id);
    expect(operations.last.payload, {
      'head_name': 'Asha Noor Updated',
      'member_count': 5,
    });
  });

  test(
    'update operation uses the next sequence and only changed fields',
    () async {
      final existing = _household(
        id: 'hh-0004',
        serverId: 'hh-0004',
        headName: 'Peter Kamau',
        memberCount: 2,
        settlement: 'Mathare Valley',
        lastSeq: 3,
      );
      await householdRepository.createHousehold(existing);

      await householdRepository.updateHouseholdWithOperation(
        id: existing.id,
        headName: 'Peter Kamau',
        memberCount: 6,
        settlement: 'Korogocho',
        opId: 'op-update-2',
      );

      final saved = await householdRepository.getHouseholdById(existing.id);
      final operation = (await syncRepository.getOperationsForHousehold(
        existing.id,
      )).single;

      expect(saved!.id, existing.id);
      expect(saved.lastSeq, 4);
      expect(operation.seq, saved.lastSeq);
      expect(operation.recordId, existing.serverId);
      expect(operation.type, 'update');
      expect(operation.payload, {'member_count': 6, 'settlement': 'Korogocho'});
    },
  );

  test(
    'rolls back the household update when the sync operation insert fails',
    () async {
      final existing = _household(id: 'hh-existing');
      await householdRepository.createHouseholdWithOperation(
        existing,
        _operation(opId: 'op-existing', householdId: existing.id),
      );

      final target = _household(
        id: 'hh-target',
        headName: 'Grace Achieng',
        memberCount: 5,
        settlement: 'Mathare Valley',
        lastSeq: 2,
      );
      await householdRepository.createHousehold(target);

      await expectLater(
        householdRepository.updateHouseholdWithOperation(
          id: target.id,
          headName: 'Grace Achieng Updated',
          memberCount: 8,
          settlement: 'Korogocho',
          opId: 'op-existing',
        ),
        throwsA(isA<DatabaseException>()),
      );

      final saved = await householdRepository.getHouseholdById(target.id);
      expect(saved!.headName, target.headName);
      expect(saved.memberCount, target.memberCount);
      expect(saved.settlement, target.settlement);
      expect(saved.lastSeq, target.lastSeq);
      expect(
        await syncRepository.getOperationsForHousehold(target.id),
        isEmpty,
      );
    },
  );

  test('inserts initial server households', () async {
    when(() => apiService.fetchHouseholds()).thenAnswer(
      (_) async => [
        _serverHousehold(
          id: 'hh-0001',
          headName: 'Amina Wanjiru',
          memberCount: 4,
          settlement: 'Kibera North',
        ),
        _serverHousehold(
          id: 'hh-0002',
          headName: 'Joseph Otieno',
          memberCount: 3,
          settlement: 'Kibera North',
        ),
      ],
    );

    await householdRepository.fetchInitialHouseholds();

    final saved = await householdRepository.getHouseholdById('hh-0001');
    final second = await householdRepository.getHouseholdById('hh-0002');

    expect(saved, isNotNull);
    expect(saved!.id, 'hh-0001');
    expect(saved.serverId, 'hh-0001');
    expect(saved.headName, 'Amina Wanjiru');
    expect(saved.memberCount, 4);
    expect(saved.settlement, 'Kibera North');
    expect(saved.lastSeq, 0);
    expect(second!.serverId, 'hh-0002');
    expect(await syncRepository.getAllPendingOperations(), isEmpty);
  });

  test('repeated initial fetch does not create duplicate households', () async {
    when(() => apiService.fetchHouseholds()).thenAnswer(
      (_) async => [_serverHousehold(id: 'hh-0001', headName: 'Amina Wanjiru')],
    );

    await householdRepository.fetchInitialHouseholds();
    await householdRepository.fetchInitialHouseholds();

    final households = await householdRepository.getHouseholds();
    expect(households, hasLength(1));
    expect(households.single.id, 'hh-0001');
  });

  test(
    'initial fetch does not overwrite an existing local household',
    () async {
      final createdAt = DateTime.utc(2026, 11, 26, 9);
      final local = _household(
        id: 'hh-0001',
        headName: 'Local Name',
        memberCount: 2,
        settlement: 'Local Settlement',
        lastSeq: 1,
        createdAt: createdAt,
      );
      final offline = _household(
        id: 'local-uuid',
        headName: 'Offline Household',
      );
      await householdRepository.createHousehold(local);
      await householdRepository.createHousehold(offline);

      when(() => apiService.fetchHouseholds()).thenAnswer(
        (_) async => [
          _serverHousehold(
            id: 'hh-0001',
            headName: 'Server Name',
            memberCount: 9,
            settlement: 'Server Settlement',
          ),
          _serverHousehold(id: 'hh-0002', headName: 'Joseph Otieno'),
        ],
      );

      await householdRepository.fetchInitialHouseholds();

      final savedLocal = await householdRepository.getHouseholdById('hh-0001');
      final savedOffline = await householdRepository.getHouseholdById(
        'local-uuid',
      );
      final inserted = await householdRepository.getHouseholdById('hh-0002');

      expect(savedLocal!.headName, 'Local Name');
      expect(savedLocal.memberCount, 2);
      expect(savedLocal.settlement, 'Local Settlement');
      expect(savedLocal.serverId, isNull);
      expect(savedLocal.lastSeq, 1);
      expect(savedLocal.createdAt, createdAt);
      expect(savedOffline!.headName, 'Offline Household');
      expect(inserted!.headName, 'Joseph Otieno');
      expect(inserted.serverId, 'hh-0002');
    },
  );

  test('initial fetch leaves pending sync operations unchanged', () async {
    final local = _household(id: 'local-uuid', headName: 'Offline Household');
    final operation = _operation(
      opId: 'op-local',
      householdId: local.id,
      type: 'create',
      seq: 1,
    );
    await householdRepository.createHouseholdWithOperation(local, operation);

    when(() => apiService.fetchHouseholds()).thenAnswer(
      (_) async => [_serverHousehold(id: 'hh-0001', headName: 'Amina Wanjiru')],
    );

    await householdRepository.fetchInitialHouseholds();

    final operations = await syncRepository.getOperationsForHousehold(local.id);
    expect(operations, hasLength(1));
    expect(operations.single.opId, operation.opId);
    expect(operations.single.type, operation.type);
    expect(operations.single.seq, operation.seq);
    expect(operations.single.payload, operation.payload);
    expect(operations.single.state, operation.state);
    expect(operations.single.householdId, local.id);
    expect(
      (await householdRepository.getHouseholdById(local.id))!.headName,
      local.headName,
    );
  });

  test('API failure does not change local households or operations', () async {
    final local = _household(id: 'local-uuid', headName: 'Offline Household');
    final operation = _operation(opId: 'op-local', householdId: local.id);
    await householdRepository.createHouseholdWithOperation(local, operation);

    when(
      () => apiService.fetchHouseholds(),
    ).thenThrow(ApiException('GET /households failed', statusCode: 503));

    await expectLater(
      householdRepository.fetchInitialHouseholds(),
      throwsA(isA<ApiException>()),
    );

    final households = await householdRepository.getHouseholds();
    final operations = await syncRepository.getOperationsForHousehold(local.id);
    expect(households, hasLength(1));
    expect(households.single.id, local.id);
    expect(households.single.headName, local.headName);
    expect(operations, hasLength(1));
    expect(operations.single.opId, operation.opId);
    expect(operations.single.payload, operation.payload);
  });

  test(
    'maps a created household to its server id and updates later operations',
    () async {
      final local = _household(id: 'local-uuid', lastSeq: 3);
      final other = _household(id: 'other-local', headName: 'Joseph Otieno');
      await householdRepository.createHousehold(local);
      await householdRepository.createHousehold(other);

      final create = _operation(
        opId: 'op-create',
        householdId: local.id,
        type: 'create',
        seq: 1,
      );
      final firstUpdate = _operation(
        opId: 'op-update-1',
        householdId: local.id,
        type: 'update',
        seq: 2,
      );
      final secondUpdate = _operation(
        opId: 'op-update-2',
        householdId: local.id,
        type: 'update',
        seq: 3,
      );
      final otherOperation = _operation(
        opId: 'op-other',
        householdId: other.id,
        type: 'create',
        seq: 1,
      );
      for (final operation in [
        create,
        firstUpdate,
        secondUpdate,
        otherOperation,
      ]) {
        await database.insert('sync_operations', operation.toMap());
      }

      await householdRepository.completeCreateOperation(
        opId: create.opId,
        householdId: local.id,
        serverId: 'hh-0031',
      );

      final saved = await householdRepository.getHouseholdById(local.id);
      final operations = await syncRepository.getOperationsForHousehold(
        local.id,
      );
      final untouched = await syncRepository.getOperationsForHousehold(
        other.id,
      );

      expect(saved, isNotNull);
      expect(saved!.id, local.id);
      expect(saved.serverId, 'hh-0031');
      expect(saved.headName, local.headName);
      expect(saved.lastSeq, local.lastSeq);

      expect(operations.map((operation) => operation.opId), [
        create.opId,
        firstUpdate.opId,
        secondUpdate.opId,
      ]);
      expect(operations.map((operation) => operation.householdId).toSet(), {
        local.id,
      });
      expect(operations.first.recordId, isNull);
      expect(operations[1].recordId, 'hh-0031');
      expect(operations[2].recordId, 'hh-0031');
      expect(operations.first.state, 'completed');
      expect(operations.first.type, 'create');
      expect(operations[1].state, 'pending');
      expect(operations[2].state, 'pending');
      expect(untouched.single.recordId, isNull);
      expect(untouched.single.state, 'pending');
      expect(untouched.single.householdId, other.id);
    },
  );

  test('logs successful and failed server ID mapping', () async {
    final logs = <LogEntry>[];
    final logged = HouseholdRepository(
      appDatabase: AppDatabase.forTesting(database),
      apiService: apiService,
      logger: AppLogger(
        clock: () => DateTime.utc(2026, 11, 27, 12),
        write: logs.add,
      ),
    );
    final local = _household(id: 'local-uuid', lastSeq: 2);
    await logged.createHousehold(local);
    await database.insert(
      'sync_operations',
      _operation(opId: 'op-create', householdId: local.id, seq: 1).toMap(),
    );
    await database.insert(
      'sync_operations',
      _operation(
        opId: 'op-update',
        householdId: local.id,
        type: 'update',
        seq: 2,
      ).toMap(),
    );

    await logged.completeCreateOperation(
      opId: 'op-create',
      householdId: local.id,
      serverId: 'hh-0031',
    );

    final success = logs.singleWhere(
      (entry) => entry.message.startsWith('[ID MAPPING: successful]'),
    );
    expect(success.operationId, 'op-create');
    expect(success.householdId, 'local-uuid');
    expect(success.serverId, 'hh-0031');
    expect(success.message, contains('local=local-uuid'));
    expect(success.message, contains('server=hh-0031'));
    expect(success.message, contains('later operations updated=1'));
    expect(
      logs.map((entry) => entry.message),
      contains('Create server ID mapping completed'),
    );

    logs.clear();
    await expectLater(
      logged.completeCreateOperation(
        opId: 'missing',
        householdId: local.id,
        serverId: 'hh-0099',
      ),
      throwsA(isA<StateError>()),
    );
    final failure = logs.singleWhere(
      (entry) => entry.message.startsWith('[ID MAPPING: failed]'),
    );
    expect(failure.level, LogLevel.error);
    expect(failure.operationId, 'missing');
    expect(failure.householdId, local.id);
    expect(failure.serverId, 'hh-0099');
    expect(failure.message, contains('local=${local.id}'));
    expect(failure.message, contains('server=hh-0099'));
    expect(
      logs.map((entry) => entry.message),
      contains('Create server ID mapping failed'),
    );
  });

  test('a repeated create completion keeps the same mapping', () async {
    final local = _household(id: 'local-uuid', lastSeq: 2);
    await householdRepository.createHousehold(local);
    final create = _operation(
      opId: 'op-create',
      householdId: local.id,
      type: 'create',
      seq: 1,
    );
    final update = _operation(
      opId: 'op-update',
      householdId: local.id,
      type: 'update',
      seq: 2,
    );
    await database.insert('sync_operations', create.toMap());
    await database.insert('sync_operations', update.toMap());

    await householdRepository.completeCreateOperation(
      opId: create.opId,
      householdId: local.id,
      serverId: 'hh-0031',
    );
    await householdRepository.completeCreateOperation(
      opId: create.opId,
      householdId: local.id,
      serverId: 'hh-0031',
    );

    final households = await householdRepository.getHouseholds();
    final operations = await syncRepository.getOperationsForHousehold(local.id);

    expect(households, hasLength(1));
    expect(households.single.id, local.id);
    expect(households.single.serverId, 'hh-0031');
    expect(operations, hasLength(2));
    expect(operations.first.state, 'completed');
    expect(operations.first.recordId, isNull);
    expect(operations.last.recordId, 'hh-0031');
  });

  test('throws when the create operation does not exist', () async {
    final local = _household(id: 'local-uuid');
    await householdRepository.createHousehold(local);

    await expectLater(
      householdRepository.completeCreateOperation(
        opId: 'missing-op',
        householdId: local.id,
        serverId: 'hh-0031',
      ),
      throwsA(isA<StateError>()),
    );

    expect(
      (await householdRepository.getHouseholdById(local.id))!.serverId,
      isNull,
    );
  });

  test('rolls back when the operation is not a create', () async {
    final local = _household(id: 'local-uuid', lastSeq: 2);
    await householdRepository.createHousehold(local);
    final update = _operation(
      opId: 'op-update',
      householdId: local.id,
      type: 'update',
      seq: 2,
      state: 'pending',
    );
    await database.insert('sync_operations', update.toMap());

    await expectLater(
      householdRepository.completeCreateOperation(
        opId: update.opId,
        householdId: local.id,
        serverId: 'hh-0031',
      ),
      throwsA(isA<StateError>()),
    );

    final saved = await householdRepository.getHouseholdById(local.id);
    final operations = await syncRepository.getOperationsForHousehold(local.id);
    expect(saved!.id, local.id);
    expect(saved.serverId, isNull);
    expect(operations.single.state, 'pending');
    expect(operations.single.recordId, isNull);
    expect(operations.single.householdId, local.id);
  });

  test(
    'a server id owned by another household is a mapping conflict',
    () async {
      final nextRetryAt = DateTime.utc(2026, 11, 27, 12);
      final mapped = _household(
        id: 'dfb07d69-79c5-4908-bccf-da6789ec2648',
        serverId: 'hh-0031',
        headName: 'Ramesh Kumar',
      );
      final local = _household(
        id: 'd31e3ba0-c982-419a-937f-f58bf1b9afb4',
        headName: 'Lost Ack Final Test',
        lastSeq: 2,
      );
      await householdRepository.createHousehold(mapped);
      await householdRepository.createHousehold(local);

      final create = _operation(
        opId: 'op-create',
        householdId: local.id,
        type: 'create',
        seq: 1,
        state: 'retrying',
        attemptCount: 1,
        nextRetryAt: nextRetryAt,
        lastError: 'Connection closed before full header was received',
        payload: const {
          'head_name': 'Lost Ack Final Test',
          'member_count': 4,
          'settlement': 'Test',
        },
      );
      final update = _operation(
        opId: 'op-update',
        householdId: local.id,
        type: 'update',
        seq: 2,
      );
      await database.insert('sync_operations', create.toMap());
      await database.insert('sync_operations', update.toMap());

      await expectLater(
        householdRepository.completeCreateOperation(
          opId: create.opId,
          householdId: local.id,
          serverId: 'hh-0031',
        ),
        throwsA(
          isA<ServerIdMappingConflictException>()
              .having((error) => error.serverId, 'serverId', 'hh-0031')
              .having((error) => error.householdId, 'householdId', local.id)
              .having(
                (error) => error.existingHouseholdId,
                'existingHouseholdId',
                mapped.id,
              ),
        ),
      );

      final saved = await householdRepository.getHouseholdById(local.id);
      final owner = await householdRepository.getHouseholdById(mapped.id);
      final operations = await syncRepository.getOperationsForHousehold(
        local.id,
      );
      expect(saved!.id, local.id);
      expect(saved.serverId, isNull);
      expect(saved.headName, 'Lost Ack Final Test');
      expect(owner!.id, mapped.id);
      expect(owner.serverId, 'hh-0031');
      expect(owner.headName, 'Ramesh Kumar');
      expect(operations.first.opId, create.opId);
      expect(operations.first.state, 'retrying');
      expect(operations.first.seq, 1);
      expect(operations.first.payload, create.payload);
      expect(operations.first.attemptCount, 1);
      expect(operations.first.nextRetryAt, nextRetryAt);
      expect(
        operations.first.lastError,
        'Connection closed before full header was received',
      );
      expect(operations.last.state, 'pending');
      expect(operations.last.recordId, isNull);
    },
  );
}

Household _serverHousehold({
  required String id,
  required String headName,
  int memberCount = 4,
  String settlement = 'Kibera North',
}) {
  final updatedAt = DateTime.utc(2026, 11, 26, 12);
  return Household(
    id: id,
    serverId: id,
    headName: headName,
    memberCount: memberCount,
    settlement: settlement,
    createdAt: updatedAt,
    updatedAt: updatedAt,
  );
}

Household _household({
  required String id,
  String? serverId,
  String headName = 'Asha Noor',
  int memberCount = 4,
  String settlement = 'Kibera North',
  int lastSeq = 1,
  DateTime? createdAt,
  DateTime? updatedAt,
}) {
  final created = createdAt ?? DateTime.utc(2026, 11, 26, 9);
  return Household(
    id: id,
    serverId: serverId,
    headName: headName,
    memberCount: memberCount,
    settlement: settlement,
    lastSeq: lastSeq,
    createdAt: created,
    updatedAt: updatedAt ?? created,
  );
}

SyncOperation _operation({
  required String opId,
  required String householdId,
  String type = 'create',
  int seq = 1,
  Map<String, dynamic>? payload,
  String state = 'pending',
  int attemptCount = 0,
  DateTime? nextRetryAt,
  String? lastError,
  DateTime? createdAt,
}) {
  return SyncOperation(
    opId: opId,
    householdId: householdId,
    type: type,
    seq: seq,
    payload:
        payload ??
        {
          'head_name': 'Asha Noor',
          'member_count': 4,
          'settlement': 'Kibera North',
        },
    state: state,
    attemptCount: attemptCount,
    nextRetryAt: nextRetryAt,
    lastError: lastError,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 26, 9),
  );
}
