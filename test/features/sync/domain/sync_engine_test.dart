import 'dart:async';

import 'package:egov_household_survey/core/database/app_database.dart';
import 'package:egov_household_survey/core/logging/app_logger.dart';
import 'package:egov_household_survey/core/network/api_service.dart';
import 'package:egov_household_survey/core/settings/settings_repository.dart';
import 'package:egov_household_survey/features/households/data/household_repository.dart';
import 'package:egov_household_survey/features/households/domain/household.dart';
import 'package:egov_household_survey/features/sync/data/sync_repository.dart';
import 'package:egov_household_survey/features/sync/domain/retry_policy.dart';
import 'package:egov_household_survey/features/sync/domain/sync_engine.dart';
import 'package:egov_household_survey/features/sync/domain/sync_operation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MockApiService extends Mock implements ApiService {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    registerFallbackValue(
      SyncOperation(
        opId: 'fallback',
        householdId: 'fallback',
        type: 'create',
        seq: 1,
        payload: const {},
        createdAt: DateTime.utc(2026),
      ),
    );
  });

  late Database database;
  late _MockApiService apiService;
  late _MockSettingsRepository settings;
  late HouseholdRepository householdRepository;
  late SyncRepository syncRepository;
  late SyncEngine engine;

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
    settings = _MockSettingsRepository();
    householdRepository = HouseholdRepository(
      appDatabase: appDatabase,
      apiService: apiService,
    );
    syncRepository = SyncRepository(appDatabase: appDatabase);
    engine = SyncEngine(
      apiService: apiService,
      syncRepository: syncRepository,
      householdRepository: householdRepository,
      settingsRepository: settings,
      retryPolicy: RetryPolicy(random: () => 0.5),
    );
    when(() => settings.isOnline()).thenAnswer((_) async => true);
  });

  tearDown(() async {
    await database.close();
  });

  test('offline mode makes no API calls', () async {
    when(() => settings.isOnline()).thenAnswer((_) async => false);
    await _insertHousehold(database, 'local-1');
    await _insertOperation(
      database,
      _operation(opId: 'op-1', householdId: 'local-1'),
    );

    await engine.syncPendingOperations();

    verifyNever(() => apiService.syncOperation(any()));
    final saved = await syncRepository.getOperationsForHousehold('local-1');
    expect(saved.single.state, 'pending');
  });

  test('a successful create maps the server id', () async {
    await _insertHousehold(database, 'local-1');
    final operation = _operation(opId: 'op-create', householdId: 'local-1');
    await _insertOperation(database, operation);
    when(() => apiService.syncOperation(any())).thenAnswer(
      (_) async => const SyncResult(
        opId: 'op-create',
        status: SyncResultStatus.applied,
        serverHouseholdId: 'hh-0031',
      ),
    );

    await engine.syncPendingOperations();

    final sent =
        verify(() => apiService.syncOperation(captureAny())).captured.single
            as SyncOperation;
    expect(sent.opId, operation.opId);
    expect(sent.payload, operation.payload);

    final household = await householdRepository.getHouseholdById('local-1');
    final saved = await syncRepository.getOperationsForHousehold('local-1');
    expect(household!.id, 'local-1');
    expect(household.serverId, 'hh-0031');
    expect(saved.single.state, 'completed');
    expect(saved.single.recordId, isNull);
    expect(saved.single.payload, operation.payload);
  });

  test('a successful update completes its operation', () async {
    await _insertHousehold(database, 'local-1', serverId: 'hh-0001');
    final operation = _operation(
      opId: 'op-update',
      householdId: 'local-1',
      type: 'update',
      recordId: 'hh-0001',
    );
    await _insertOperation(database, operation);
    when(() => apiService.syncOperation(any())).thenAnswer(
      (_) async =>
          const SyncResult(opId: 'op-update', status: SyncResultStatus.applied),
    );

    await engine.syncPendingOperations();

    final saved = (await syncRepository.getOperationsForHousehold(
      'local-1',
    )).single;
    expect(saved.state, 'completed');
    expect(saved.opId, operation.opId);
    expect(saved.recordId, 'hh-0001');
    expect(saved.payload, operation.payload);
    expect(
      (await householdRepository.getHouseholdById('local-1'))!.id,
      'local-1',
    );
  });

  test('a duplicate create response maps the server id', () async {
    await _insertHousehold(database, 'local-1');
    await _insertOperation(
      database,
      _operation(opId: 'op-create', householdId: 'local-1'),
    );
    when(() => apiService.syncOperation(any())).thenAnswer(
      (_) async => const SyncResult(
        opId: 'op-create',
        status: SyncResultStatus.duplicate,
        serverHouseholdId: 'hh-0031',
      ),
    );

    await engine.syncPendingOperations();

    final household = await householdRepository.getHouseholdById('local-1');
    final saved = (await syncRepository.getOperationsForHousehold(
      'local-1',
    )).single;
    expect(household!.id, 'local-1');
    expect(household.serverId, 'hh-0031');
    expect(saved.state, 'completed');
    expect(saved.recordId, isNull);
  });

  test(
    'a duplicate create with a server id and an error is completed',
    () async {
      await _insertHousehold(database, 'local-1');
      final operation = _operation(
        opId: 'op-create',
        householdId: 'local-1',
        payload: const {
          'head_name': 'Asha Noor',
          'member_count': 4,
          'settlement': 'Kibera North',
        },
      );
      await _insertOperation(database, operation);
      when(() => apiService.syncOperation(any())).thenAnswer(
        (_) async => const SyncResult(
          opId: 'op-create',
          status: SyncResultStatus.duplicate,
          serverHouseholdId: 'hh-0031',
          error: 'member_count must be an integer from 1 to 30',
        ),
      );

      await engine.syncPendingOperations();

      final household = await householdRepository.getHouseholdById('local-1');
      final saved = (await syncRepository.getOperationsForHousehold(
        'local-1',
      )).single;
      expect(household!.serverId, 'hh-0031');
      expect(saved.state, 'completed');
      expect(saved.opId, operation.opId);
      expect(saved.seq, operation.seq);
      expect(saved.payload, operation.payload);
    },
  );

  test(
    'a duplicate create without a server id and with an error is rejected',
    () async {
      await _insertHousehold(database, 'local-1');
      final operation = _operation(
        opId: 'op-create',
        householdId: 'local-1',
        payload: const {
          'head_name': 'Asha Noor',
          'member_count': 88,
          'settlement': 'Kibera North',
        },
      );
      await _insertOperation(database, operation);
      when(() => apiService.syncOperation(any())).thenAnswer(
        (_) async => const SyncResult(
          opId: 'op-create',
          status: SyncResultStatus.duplicate,
          error: 'member_count must be an integer from 1 to 30',
        ),
      );

      await engine.syncPendingOperations();
      await engine.syncPendingOperations();

      verify(() => apiService.syncOperation(any())).called(1);
      final household = await householdRepository.getHouseholdById('local-1');
      final saved = (await syncRepository.getOperationsForHousehold(
        'local-1',
      )).single;
      expect(household!.id, 'local-1');
      expect(household.serverId, isNull);
      expect(household.headName, 'Asha Noor');
      expect(saved.state, 'rejected');
      expect(saved.opId, operation.opId);
      expect(saved.seq, operation.seq);
      expect(saved.payload, operation.payload);
      expect(saved.attemptCount, operation.attemptCount);
      expect(saved.nextRetryAt, isNull);
      expect(saved.lastError, 'member_count must be an integer from 1 to 30');
    },
  );

  test('a stale response completes the operation', () async {
    await _insertHousehold(database, 'local-1', serverId: 'hh-0001');
    final operation = _operation(
      opId: 'op-update',
      householdId: 'local-1',
      type: 'update',
      recordId: 'hh-0001',
    );
    await _insertOperation(database, operation);
    when(() => apiService.syncOperation(any())).thenAnswer(
      (_) async => const SyncResult(
        opId: 'op-update',
        status: SyncResultStatus.stale,
        error: 'an operation with a higher seq was already applied',
      ),
    );

    await engine.syncPendingOperations();

    final saved = (await syncRepository.getOperationsForHousehold(
      'local-1',
    )).single;
    expect(saved.state, 'completed');
    expect(saved.opId, operation.opId);
    expect(saved.payload, operation.payload);
  });

  test(
    'a rejected response stays rejected and later operations are not sent',
    () async {
      await _insertHousehold(database, 'local-1');
      final first = _operation(
        opId: 'op-1',
        householdId: 'local-1',
        seq: 1,
        createdAt: DateTime.utc(2026, 11, 27, 10),
      );
      final second = _operation(
        opId: 'op-2',
        householdId: 'local-1',
        type: 'update',
        seq: 2,
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      );
      await _insertOperation(database, first);
      await _insertOperation(database, second);
      when(() => apiService.syncOperation(any())).thenAnswer(
        (_) async => const SyncResult(
          opId: 'op-1',
          status: SyncResultStatus.rejected,
          error: 'household not found',
        ),
      );

      await engine.syncPendingOperations();

      final sent = verify(
        () => apiService.syncOperation(captureAny()),
      ).captured.cast<SyncOperation>();
      expect(sent.map((operation) => operation.opId), ['op-1']);
      expect(sent.single.payload, first.payload);

      final saved = await syncRepository.getOperationsForHousehold('local-1');
      expect(saved.first.state, 'rejected');
      expect(saved.first.lastError, 'household not found');
      expect(saved.first.payload, first.payload);
      expect(saved.last.state, 'blocked');
      expect(saved.last.opId, 'op-2');
    },
  );

  test(
    'another household continues syncing when one household is rejected',
    () async {
      await _insertHousehold(database, 'local-a');
      await _insertHousehold(database, 'local-b', serverId: 'hh-0002');
      await _insertOperation(
        database,
        _operation(
          opId: 'op-a',
          householdId: 'local-a',
          createdAt: DateTime.utc(2026, 11, 27, 10),
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-b',
          householdId: 'local-b',
          type: 'update',
          recordId: 'hh-0002',
          createdAt: DateTime.utc(2026, 11, 27, 10, 1),
        ),
      );
      when(() => apiService.syncOperation(any())).thenAnswer((
        invocation,
      ) async {
        final operation =
            invocation.positionalArguments.single as SyncOperation;
        if (operation.opId == 'op-a') {
          return const SyncResult(
            opId: 'op-a',
            status: SyncResultStatus.rejected,
            error: 'rejected',
          );
        }
        return const SyncResult(opId: 'op-b', status: SyncResultStatus.applied);
      });

      await engine.syncPendingOperations();

      final sent = verify(
        () => apiService.syncOperation(captureAny()),
      ).captured.cast<SyncOperation>();
      expect(sent.map((operation) => operation.opId), ['op-a', 'op-b']);

      final rejected = await syncRepository.getOperationsForHousehold(
        'local-a',
      );
      final completed = await syncRepository.getOperationsForHousehold(
        'local-b',
      );
      expect(rejected.single.state, 'rejected');
      expect(rejected.single.lastError, 'rejected');
      expect(completed.single.state, 'completed');
    },
  );

  test(
    'repeated sync calls do not send the same operation concurrently',
    () async {
      await _insertHousehold(database, 'local-1');
      await _insertOperation(
        database,
        _operation(opId: 'op-create', householdId: 'local-1'),
      );
      final started = Completer<void>();
      final release = Completer<void>();
      when(() => apiService.syncOperation(any())).thenAnswer((_) async {
        if (!started.isCompleted) {
          started.complete();
        }
        await release.future;
        return const SyncResult(
          opId: 'op-create',
          status: SyncResultStatus.applied,
          serverHouseholdId: 'hh-0031',
        );
      });

      final first = engine.syncPendingOperations();
      await started.future;
      final second = engine.syncPendingOperations();
      release.complete();
      await Future.wait([first, second]);

      verify(() => apiService.syncOperation(any())).called(1);
      expect(
        (await householdRepository.getHouseholdById('local-1'))!.serverId,
        'hh-0031',
      );
    },
  );

  test('logs an offline sync without making an API call', () async {
    final logs = <LogEntry>[];
    final logged = _loggedEngine(
      apiService: apiService,
      syncRepository: syncRepository,
      householdRepository: householdRepository,
      settings: settings,
      logs: logs,
    );
    when(() => settings.isOnline()).thenAnswer((_) async => false);
    await _insertHousehold(database, 'local-1');
    await _insertOperation(
      database,
      _operation(opId: 'op-1', householdId: 'local-1'),
    );

    await logged.syncPendingOperations();

    final messages = logs.map((entry) => entry.message).toList();
    expect(messages.first, '[SYNC START]');
    expect(messages, contains('Sync started'));
    expect(
      messages,
      contains(
        'Online/offline check: offline, returning without network requests',
      ),
    );
    expect(messages.last, 'Sync finished');
    final summary = messages.singleWhere(
      (message) => message.startsWith('[SYNC SUMMARY]'),
    );
    expect(summary, contains('discovered=1'));
    expect(summary, contains('applied=0'));
    expect(summary, contains('failed=0'));
    expect(summary, contains('pending=1'));
    expect(summary, contains('households=0'));
    final queue = messages.singleWhere(
      (message) => message.startsWith('[QUEUE SUMMARY]'),
    );
    expect(queue, contains('[HOUSEHOLD: local-1]'));
    expect(queue, contains('CREATE seq 1 op=op-1'));
    verifyNever(() => apiService.syncOperation(any()));
  });

  test(
    'logs create mapping and completion without household details',
    () async {
      final logs = <LogEntry>[];
      final households = HouseholdRepository(
        appDatabase: AppDatabase.forTesting(database),
        apiService: apiService,
        logger: _recordingLogger(logs),
      );
      final logged = SyncEngine(
        apiService: apiService,
        syncRepository: syncRepository,
        householdRepository: households,
        settingsRepository: settings,
        retryPolicy: RetryPolicy(random: () => 0.5),
        logger: _recordingLogger(logs),
      );
      await _insertHousehold(database, 'local-1');
      await _insertOperation(
        database,
        _operation(opId: 'op-create', householdId: 'local-1'),
      );
      when(() => apiService.syncOperation(any())).thenAnswer(
        (_) async => const SyncResult(
          opId: 'op-create',
          status: SyncResultStatus.applied,
          serverHouseholdId: 'hh-0031',
        ),
      );

      await logged.syncPendingOperations();

      expect(
        logs
            .map((entry) => entry.message)
            .where((message) => !message.startsWith('[SYNC SUMMARY]')),
        [
          '[SYNC START]',
          'Sync started',
          '[QUEUE SUMMARY]\n'
              'pending=1\n'
              'retrying=0\n'
              'households=1\n'
              '[HOUSEHOLD: local-1]\n'
              'CREATE seq 1 op=op-create',
          'Online/offline check: online, continuing sync',
          'Discovered 1 pending and 0 retrying operations: '
              'op-create household local-1 pending seq 1',
          'Selected create operation at seq 1',
          'Sending create request',
          '[REQUEST: operation 1/1]\n'
              'type=CREATE\n'
              'seq=1\n'
              'sending to the server',
          'API response applied',
          'Mapping create operation to server id',
          'Create server ID mapping started',
          'Create server ID mapping completed',
          '[ID MAPPING: successful]\n'
              'local=local-1\n'
              'server=hh-0031\n'
              'later operations updated=0',
          'Operation marked completed',
          '[RESPONSE: applied]\noutcome=completed',
          'Discovered 0 pending and 0 retrying operations',
          'Sync finished',
        ],
      );
      expect(
        logs
            .where((entry) => !entry.message.startsWith('[SYNC SUMMARY]'))
            .map((entry) => entry.category),
        [
          LogCategory.sync,
          LogCategory.sync,
          LogCategory.queue,
          LogCategory.sync,
          LogCategory.queue,
          LogCategory.sync,
          LogCategory.api,
          LogCategory.api,
          LogCategory.api,
          LogCategory.household,
          LogCategory.household,
          LogCategory.household,
          LogCategory.household,
          LogCategory.sync,
          LogCategory.sync,
          LogCategory.queue,
          LogCategory.sync,
        ],
      );
      final selected = logs.singleWhere(
        (entry) => entry.message.startsWith('Selected '),
      );
      expect(selected.operationId, 'op-create');
      expect(selected.householdId, 'local-1');
      final mapping = logs.singleWhere(
        (entry) => entry.message == 'Mapping create operation to server id',
      );
      expect(mapping.serverId, 'hh-0031');
      expect(mapping.operationId, 'op-create');
      final text = logs.map((entry) => entry.line).join('\n');
      expect(text, isNot(contains('Asha Noor')));
      expect(text, isNot(contains('Kibera North')));
      expect(text, isNot(contains('head_name')));
    },
  );

  test('logs a sync failure with the operation id', () async {
    final logs = <LogEntry>[];
    final logged = _loggedEngine(
      apiService: apiService,
      syncRepository: syncRepository,
      householdRepository: householdRepository,
      settings: settings,
      logs: logs,
    );
    await _insertHousehold(database, 'local-1');
    await _insertOperation(
      database,
      _operation(opId: 'op-create', householdId: 'local-1'),
    );
    when(
      () => apiService.syncOperation(any()),
    ).thenThrow(StateError('connection closed'));

    await expectLater(
      logged.syncPendingOperations(),
      throwsA(isA<StateError>()),
    );

    expect(
      logs.map((entry) => entry.message),
      contains('Sending create request'),
    );
    final failure = logs.singleWhere((entry) => entry.message == 'Sync failed');
    expect(failure.level, LogLevel.error);
    expect(failure.operationId, 'op-create');
    expect(failure.householdId, 'local-1');
    expect(failure.error, isA<StateError>());
    expect(failure.stackTrace, isNotNull);
    final summary = logs
        .map((entry) => entry.message)
        .singleWhere((message) => message.startsWith('[SYNC SUMMARY]'));
    expect(summary, contains('discovered=1'));
    expect(summary, contains('applied=0'));
    expect(summary, contains('failed=1'));
    expect(summary, contains('pending=1'));
    expect(logs.last.message, 'Sync finished');
    expect(
      (await syncRepository.getOperationsForHousehold('local-1')).single.state,
      'pending',
    );
  });

  test('summary counters count each operation once', () async {
    final logs = <LogEntry>[];
    final logged = _loggedEngine(
      apiService: apiService,
      syncRepository: syncRepository,
      householdRepository: householdRepository,
      settings: settings,
      logs: logs,
    );
    await _insertHousehold(database, 'local-applied');
    await _insertHousehold(database, 'local-duplicate');
    await _insertHousehold(database, 'local-stale', serverId: 'hh-0003');
    await _insertHousehold(database, 'local-rejected', serverId: 'hh-0004');
    await _insertOperation(
      database,
      _operation(
        opId: 'op-applied',
        householdId: 'local-applied',
        createdAt: DateTime.utc(2026, 11, 27, 10),
      ),
    );
    await _insertOperation(
      database,
      _operation(
        opId: 'op-duplicate',
        householdId: 'local-duplicate',
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      ),
    );
    await _insertOperation(
      database,
      _operation(
        opId: 'op-stale',
        householdId: 'local-stale',
        type: 'update',
        seq: 2,
        recordId: 'hh-0003',
        state: 'retrying',
        nextRetryAt: DateTime.utc(2020, 1, 1),
        createdAt: DateTime.utc(2026, 11, 27, 10, 2),
      ),
    );
    await _insertOperation(
      database,
      _operation(
        opId: 'op-rejected',
        householdId: 'local-rejected',
        type: 'update',
        recordId: 'hh-0004',
        createdAt: DateTime.utc(2026, 11, 27, 10, 3),
      ),
    );
    when(() => apiService.syncOperation(any())).thenAnswer((invocation) async {
      final operation = invocation.positionalArguments.single as SyncOperation;
      return switch (operation.opId) {
        'op-applied' => const SyncResult(
          opId: 'op-applied',
          status: SyncResultStatus.applied,
          serverHouseholdId: 'hh-0031',
        ),
        'op-duplicate' => const SyncResult(
          opId: 'op-duplicate',
          status: SyncResultStatus.duplicate,
          serverHouseholdId: 'hh-0032',
        ),
        'op-stale' => const SyncResult(
          opId: 'op-stale',
          status: SyncResultStatus.stale,
        ),
        'op-rejected' => const SyncResult(
          opId: 'op-rejected',
          status: SyncResultStatus.rejected,
          error: 'head name is empty',
        ),
        _ => throw StateError(operation.opId),
      };
    });

    await logged.syncPendingOperations();

    final queue = logs
        .map((entry) => entry.message)
        .singleWhere((message) => message.startsWith('[QUEUE SUMMARY]'));
    expect(
      queue,
      '[QUEUE SUMMARY]\n'
      'pending=3\n'
      'retrying=1\n'
      'households=4\n'
      '[HOUSEHOLD: local-applied]\n'
      'CREATE seq 1 op=op-applied\n'
      '[HOUSEHOLD: local-duplicate]\n'
      'CREATE seq 1 op=op-duplicate\n'
      '[HOUSEHOLD: local-stale]\n'
      'UPDATE seq 2 op=op-stale\n'
      '[HOUSEHOLD: local-rejected]\n'
      'UPDATE seq 1 op=op-rejected',
    );
    final summary = logs
        .map((entry) => entry.message)
        .singleWhere((message) => message.startsWith('[SYNC SUMMARY]'));
    expect(summary, contains('discovered=4'));
    expect(summary, contains('applied=1'));
    expect(summary, contains('duplicate=1'));
    expect(summary, contains('stale=1'));
    expect(summary, contains('rejected=1'));
    expect(summary, contains('failed=0'));
    expect(summary, contains('pending=0'));
    expect(summary, contains('households=4'));
    expect(summary, contains('duration='));
    expect(
      logs
          .map((entry) => entry.message)
          .where((message) => message.startsWith('[RESPONSE:')),
      [
        '[RESPONSE: applied]\noutcome=completed',
        '[RESPONSE: duplicate]\noutcome=completed',
        '[RESPONSE: stale]\noutcome=completed',
        '[RESPONSE: rejected]\noutcome=rejected\nerror=head name is empty',
      ],
    );
    expect(
      (await syncRepository.getOperationsForHousehold(
        'local-rejected',
      )).single.state,
      'rejected',
    );
  });

  test('a network failure schedules one retry', () async {
    final logs = <LogEntry>[];
    final logged = _loggedEngine(
      apiService: apiService,
      syncRepository: syncRepository,
      householdRepository: householdRepository,
      settings: settings,
      logs: logs,
    );
    await _insertHousehold(database, 'local-1');
    final operation = _operation(opId: 'op-create', householdId: 'local-1');
    await _insertOperation(database, operation);
    when(
      () => apiService.syncOperation(any()),
    ).thenThrow(TransportException('connection closed'));
    final before = DateTime.now().toUtc();

    await logged.syncPendingOperations();
    await logged.syncPendingOperations();

    final after = DateTime.now().toUtc();
    verify(() => apiService.syncOperation(any())).called(1);
    final saved = (await syncRepository.getOperationsForHousehold(
      'local-1',
    )).single;
    expect(saved.state, 'retrying');
    expect(saved.attemptCount, 1);
    expect(saved.opId, operation.opId);
    expect(saved.householdId, operation.householdId);
    expect(saved.seq, operation.seq);
    expect(saved.payload, operation.payload);
    expect(saved.lastError, 'connection closed');
    expect(
      saved.nextRetryAt!.isBefore(before.add(const Duration(seconds: 2))),
      isFalse,
    );
    expect(
      saved.nextRetryAt!.isAfter(after.add(const Duration(seconds: 2))),
      isFalse,
    );
    final retry = logs.singleWhere(
      (entry) => entry.message.startsWith('[RETRY]'),
    );
    expect(retry.message, contains('attempt=1'));
    expect(retry.message, contains('next_retry_at='));
    expect(retry.message, contains('reason=connection closed'));
  });

  test('HTTP 503 uses Retry-After as the minimum wait', () async {
    await _insertHousehold(database, 'local-1');
    final operation = _operation(opId: 'op-create', householdId: 'local-1');
    await _insertOperation(database, operation);
    when(() => apiService.syncOperation(any())).thenThrow(
      ApiException(
        'POST /sync failed',
        statusCode: 503,
        retryAfter: const Duration(seconds: 5),
      ),
    );
    final before = DateTime.now().toUtc();

    await engine.syncPendingOperations();

    final after = DateTime.now().toUtc();
    final saved = (await syncRepository.getOperationsForHousehold(
      'local-1',
    )).single;
    expect(saved.state, 'retrying');
    expect(saved.attemptCount, 1);
    expect(saved.opId, operation.opId);
    expect(saved.payload, operation.payload);
    expect(saved.lastError, contains('503'));
    expect(
      saved.nextRetryAt!.isBefore(before.add(const Duration(seconds: 5))),
      isFalse,
    );
    expect(
      saved.nextRetryAt!.isAfter(after.add(const Duration(seconds: 5))),
      isFalse,
    );
    expect(
      saved.nextRetryAt!.isBefore(before.add(const Duration(seconds: 4))),
      isFalse,
    );
  });

  test(
    'HTTP 400 is parked without a retry and another household continues',
    () async {
      await _insertHousehold(database, 'local-a');
      await _insertHousehold(database, 'local-b', serverId: 'hh-0002');
      final failed = _operation(
        opId: 'op-400',
        householdId: 'local-a',
        attemptCount: 2,
        nextRetryAt: DateTime.utc(2026, 11, 27, 12),
        createdAt: DateTime.utc(2026, 11, 27, 10),
      );
      final later = _operation(
        opId: 'op-later',
        householdId: 'local-a',
        type: 'update',
        seq: 2,
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      );
      await _insertOperation(database, failed);
      await _insertOperation(database, later);
      await _insertOperation(
        database,
        _operation(
          opId: 'op-ok',
          householdId: 'local-b',
          type: 'update',
          recordId: 'hh-0002',
          createdAt: DateTime.utc(2026, 11, 27, 10, 2),
        ),
      );
      when(() => apiService.syncOperation(any())).thenAnswer((
        invocation,
      ) async {
        final operation =
            invocation.positionalArguments.single as SyncOperation;
        if (operation.opId == 'op-400') {
          throw ApiException('POST /sync failed', statusCode: 400);
        }
        return const SyncResult(
          opId: 'op-ok',
          status: SyncResultStatus.applied,
        );
      });

      await engine.syncPendingOperations();

      final sent = verify(
        () => apiService.syncOperation(captureAny()),
      ).captured.cast<SyncOperation>();
      expect(sent.map((operation) => operation.opId), ['op-400', 'op-ok']);
      final saved = await syncRepository.getOperationsForHousehold('local-a');
      expect(saved.first.state, 'parked');
      expect(saved.first.attemptCount, failed.attemptCount);
      expect(saved.first.nextRetryAt, isNull);
      expect(saved.first.lastError, 'HTTP 400: POST /sync failed');
      expect(saved.first.opId, failed.opId);
      expect(saved.first.householdId, failed.householdId);
      expect(saved.first.seq, failed.seq);
      expect(saved.first.payload, failed.payload);
      expect(saved.last.state, 'blocked');
      expect(saved.last.opId, later.opId);
      expect(saved.last.payload, later.payload);
      expect(
        (await syncRepository.getOperationsForHousehold(
          'local-b',
        )).single.state,
        'completed',
      );
    },
  );

  test('the retry limit parks the operation', () async {
    await _insertHousehold(database, 'local-1');
    final operation = _operation(
      opId: 'op-create',
      householdId: 'local-1',
      attemptCount: 5,
    );
    await _insertOperation(database, operation);
    final later = _operation(
      opId: 'op-later',
      householdId: 'local-1',
      type: 'update',
      seq: 2,
      createdAt: DateTime.utc(2026, 11, 27, 10, 1),
    );
    await _insertOperation(database, later);
    when(
      () => apiService.syncOperation(any()),
    ).thenThrow(TransportException('connection closed'));

    await engine.syncPendingOperations();

    verify(() => apiService.syncOperation(any())).called(1);
    final saved = await syncRepository.getOperationsForHousehold('local-1');
    expect(saved.first.state, 'parked');
    expect(saved.first.attemptCount, 5);
    expect(saved.first.lastError, 'connection closed');
    expect(saved.first.nextRetryAt, isNull);
    expect(saved.first.opId, operation.opId);
    expect(saved.first.seq, operation.seq);
    expect(saved.first.payload, operation.payload);
    expect(saved.last.state, 'blocked');
    expect(saved.last.opId, later.opId);
    expect(saved.last.payload, later.payload);
  });

  test(
    'a household waiting for retry does not block another household',
    () async {
      await _insertHousehold(database, 'local-a');
      await _insertHousehold(database, 'local-b', serverId: 'hh-0002');
      await _insertOperation(
        database,
        _operation(
          opId: 'op-waiting',
          householdId: 'local-a',
          state: 'retrying',
          attemptCount: 1,
          nextRetryAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
          createdAt: DateTime.utc(2026, 11, 27, 10),
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-b',
          householdId: 'local-b',
          type: 'update',
          recordId: 'hh-0002',
          createdAt: DateTime.utc(2026, 11, 27, 10, 1),
        ),
      );
      when(() => apiService.syncOperation(any())).thenAnswer(
        (_) async =>
            const SyncResult(opId: 'op-b', status: SyncResultStatus.applied),
      );

      await engine.syncPendingOperations();

      final sent = verify(
        () => apiService.syncOperation(captureAny()),
      ).captured.cast<SyncOperation>();
      expect(sent.map((operation) => operation.opId), ['op-b']);
      expect(
        (await syncRepository.getOperationsForHousehold(
          'local-a',
        )).single.state,
        'retrying',
      );
      expect(
        (await syncRepository.getOperationsForHousehold(
          'local-b',
        )).single.state,
        'completed',
      );
    },
  );

  test(
    'a later operation stays unsent while an earlier one is retrying',
    () async {
      await _insertHousehold(database, 'local-1');
      final first = _operation(
        opId: 'op-1',
        householdId: 'local-1',
        seq: 1,
        createdAt: DateTime.utc(2026, 11, 27, 10),
      );
      final second = _operation(
        opId: 'op-2',
        householdId: 'local-1',
        type: 'update',
        seq: 2,
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      );
      await _insertOperation(database, first);
      await _insertOperation(database, second);
      when(
        () => apiService.syncOperation(any()),
      ).thenThrow(TransportException('connection closed'));

      await engine.syncPendingOperations();

      final sent = verify(
        () => apiService.syncOperation(captureAny()),
      ).captured.cast<SyncOperation>();
      expect(sent.map((operation) => operation.opId), ['op-1']);
      final saved = await syncRepository.getOperationsForHousehold('local-1');
      expect(saved.first.state, 'retrying');
      expect(saved.first.payload, first.payload);
      expect(saved.last.state, 'pending');
      expect(saved.last.opId, second.opId);
      expect(saved.last.payload, second.payload);
    },
  );

  test(
    'a rejected create blocks later updates while another household syncs',
    () async {
      await _insertHousehold(database, 'local-a');
      await _insertHousehold(database, 'local-b', serverId: 'hh-0002');
      final create = _operation(
        opId: 'op-create',
        householdId: 'local-a',
        createdAt: DateTime.utc(2026, 11, 27, 10),
      );
      final update = _operation(
        opId: 'op-update',
        householdId: 'local-a',
        type: 'update',
        seq: 2,
        attemptCount: 3,
        nextRetryAt: DateTime.utc(2026, 11, 27, 11),
        lastError: 'earlier timeout',
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      );
      final other = _operation(
        opId: 'op-other',
        householdId: 'local-b',
        type: 'update',
        recordId: 'hh-0002',
        createdAt: DateTime.utc(2026, 11, 27, 10, 2),
      );
      await _insertOperation(database, create);
      await _insertOperation(database, update);
      await _insertOperation(database, other);
      when(() => apiService.syncOperation(any())).thenAnswer((
        invocation,
      ) async {
        final operation =
            invocation.positionalArguments.single as SyncOperation;
        if (operation.opId == 'op-create') {
          return const SyncResult(
            opId: 'op-create',
            status: SyncResultStatus.rejected,
            error: 'household not found',
          );
        }
        return const SyncResult(
          opId: 'op-other',
          status: SyncResultStatus.applied,
        );
      });

      await engine.syncPendingOperations();

      final sent = verify(
        () => apiService.syncOperation(captureAny()),
      ).captured.cast<SyncOperation>();
      expect(sent.map((operation) => operation.opId), [
        'op-create',
        'op-other',
      ]);
      final saved = await syncRepository.getOperationsForHousehold('local-a');
      expect(saved.first.state, 'rejected');
      expect(saved.first.type, 'create');
      expect(saved.last.opId, update.opId);
      expect(saved.last.type, 'update');
      expect(saved.last.state, 'blocked');
      expect(saved.last.seq, update.seq);
      expect(saved.last.payload, update.payload);
      expect(saved.last.attemptCount, update.attemptCount);
      expect(saved.last.nextRetryAt, update.nextRetryAt);
      expect(saved.last.lastError, update.lastError);
      expect(saved.last.createdAt, update.createdAt);
      expect(
        (await syncRepository.getOperationsForHousehold(
          'local-b',
        )).single.state,
        'completed',
      );
    },
  );

  test(
    'completing a rejected create unblocks dependent updates in sequence',
    () async {
      await _insertHousehold(database, 'local-1');
      await _insertOperation(
        database,
        _operation(
          opId: 'op-create',
          householdId: 'local-1',
          createdAt: DateTime.utc(2026, 11, 27, 10),
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-2',
          householdId: 'local-1',
          type: 'update',
          seq: 2,
          createdAt: DateTime.utc(2026, 11, 27, 10, 1),
        ),
      );
      await _insertOperation(
        database,
        _operation(
          opId: 'op-3',
          householdId: 'local-1',
          type: 'update',
          seq: 3,
          createdAt: DateTime.utc(2026, 11, 27, 10, 2),
        ),
      );
      when(() => apiService.syncOperation(any())).thenAnswer(
        (_) async => const SyncResult(
          opId: 'op-create',
          status: SyncResultStatus.rejected,
          error: 'household not found',
        ),
      );

      await engine.syncPendingOperations();

      var saved = await syncRepository.getOperationsForHousehold('local-1');
      expect(saved.map((operation) => operation.state), [
        'rejected',
        'blocked',
        'blocked',
      ]);

      await syncRepository.updateOperation(_copyState(saved.first, 'pending'));
      final sent = <String>[];
      when(() => apiService.syncOperation(any())).thenAnswer((
        invocation,
      ) async {
        final operation =
            invocation.positionalArguments.single as SyncOperation;
        sent.add(operation.opId);
        final current = await syncRepository.getOperationsForHousehold(
          'local-1',
        );
        if (operation.opId == 'op-2') {
          expect(current[2].state, 'blocked');
        }
        if (operation.opId == 'op-3') {
          expect(current[1].state, 'completed');
        }
        if (operation.type == 'create') {
          return const SyncResult(
            opId: 'op-create',
            status: SyncResultStatus.applied,
            serverHouseholdId: 'hh-0031',
          );
        }
        return SyncResult(
          opId: operation.opId,
          status: SyncResultStatus.applied,
        );
      });

      await engine.syncPendingOperations();

      expect(sent, ['op-create', 'op-2', 'op-3']);
      saved = await syncRepository.getOperationsForHousehold('local-1');
      expect(saved.map((operation) => operation.state), [
        'completed',
        'completed',
        'completed',
      ]);
      expect(saved.map((operation) => operation.seq), [1, 2, 3]);
      expect(saved[1].payload, saved[2].payload);
      expect(
        (await householdRepository.getHouseholdById('local-1'))!.serverId,
        'hh-0031',
      );
    },
  );

  test(
    'an existing parked operation stays parked when an earlier create resolves',
    () async {
      await _insertHousehold(database, 'local-1');
      await _insertOperation(
        database,
        _operation(
          opId: 'op-create',
          householdId: 'local-1',
          createdAt: DateTime.utc(2026, 11, 27, 10),
        ),
      );
      final parkedUpdate = _operation(
        opId: 'op-parked',
        householdId: 'local-1',
        type: 'update',
        seq: 2,
        state: 'parked',
        lastError: 'already parked',
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      );
      await _insertOperation(database, parkedUpdate);
      await _insertOperation(
        database,
        _operation(
          opId: 'op-later',
          householdId: 'local-1',
          type: 'update',
          seq: 3,
          createdAt: DateTime.utc(2026, 11, 27, 10, 2),
        ),
      );
      when(() => apiService.syncOperation(any())).thenAnswer(
        (_) async => const SyncResult(
          opId: 'op-create',
          status: SyncResultStatus.rejected,
          error: 'household not found',
        ),
      );

      await engine.syncPendingOperations();

      var saved = await syncRepository.getOperationsForHousehold('local-1');
      expect(saved.map((operation) => operation.state), [
        'rejected',
        'parked',
        'blocked',
      ]);
      expect(saved[1].lastError, 'already parked');
      expect(saved[1].payload, parkedUpdate.payload);

      await syncRepository.updateOperation(_copyState(saved.first, 'pending'));
      final sent = <String>[];
      when(() => apiService.syncOperation(any())).thenAnswer((
        invocation,
      ) async {
        final operation =
            invocation.positionalArguments.single as SyncOperation;
        sent.add(operation.opId);
        return const SyncResult(
          opId: 'op-create',
          status: SyncResultStatus.applied,
          serverHouseholdId: 'hh-0031',
        );
      });

      await engine.syncPendingOperations();

      expect(sent, ['op-create']);
      saved = await syncRepository.getOperationsForHousehold('local-1');
      expect(saved.map((operation) => operation.state), [
        'completed',
        'parked',
        'blocked',
      ]);
      expect(saved[1].opId, 'op-parked');
      expect(saved[1].lastError, 'already parked');
      expect(saved[1].seq, 2);
      expect(saved[2].state, 'blocked');
      expect(saved[2].seq, 3);
    },
  );

  test(
    'retrying a parked operation syncs the original operation and keeps later ones blocked',
    () async {
      await _insertHousehold(database, 'local-1', serverId: 'hh-0004');
      await _insertHousehold(database, 'local-2', serverId: 'hh-0005');
      final parked = _operation(
        opId: 'op-parked',
        householdId: 'local-1',
        type: 'update',
        seq: 1,
        recordId: 'hh-0004',
        state: 'parked',
        attemptCount: 5,
        nextRetryAt: DateTime.utc(2026, 11, 27, 12),
        lastError: 'HTTP 503: unavailable',
        createdAt: DateTime.utc(2026, 11, 27, 10),
      );
      final blocked = _operation(
        opId: 'op-later',
        householdId: 'local-1',
        type: 'update',
        seq: 2,
        recordId: 'hh-0004',
        state: 'blocked',
        attemptCount: 1,
        lastError: 'waiting',
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      );
      final other = _operation(
        opId: 'op-other',
        householdId: 'local-2',
        type: 'update',
        recordId: 'hh-0005',
        createdAt: DateTime.utc(2026, 11, 27, 10, 2),
      );
      await _insertOperation(database, parked);
      await _insertOperation(database, blocked);
      await _insertOperation(database, other);

      await syncRepository.retryParkedOperation(parked.opId);

      final retried = await syncRepository.getOperationsForHousehold('local-1');
      expect(retried.first.opId, parked.opId);
      expect(retried.first.householdId, parked.householdId);
      expect(retried.first.recordId, parked.recordId);
      expect(retried.first.seq, parked.seq);
      expect(retried.first.payload, parked.payload);
      expect(retried.first.createdAt, parked.createdAt);
      expect(retried.first.state, 'pending');
      expect(retried.first.attemptCount, 0);
      expect(retried.first.nextRetryAt, isNull);
      expect(retried.first.lastError, isNull);
      expect(retried.last.state, 'blocked');
      expect(retried.last.opId, blocked.opId);
      expect(retried.last.payload, blocked.payload);

      when(() => apiService.syncOperation(any())).thenAnswer((
        invocation,
      ) async {
        final operation =
            invocation.positionalArguments.single as SyncOperation;
        if (operation.opId == parked.opId) {
          final current = await syncRepository.getOperationsForHousehold(
            'local-1',
          );
          expect(current.last.state, 'blocked');
          expect(operation.payload, parked.payload);
          return const SyncResult(
            opId: 'op-parked',
            status: SyncResultStatus.applied,
          );
        }
        return SyncResult(
          opId: operation.opId,
          status: SyncResultStatus.applied,
        );
      });

      await engine.syncPendingOperations();

      final sent = verify(
        () => apiService.syncOperation(captureAny()),
      ).captured.cast<SyncOperation>();
      expect(sent.map((operation) => operation.opId), [
        'op-parked',
        'op-later',
        'op-other',
      ]);
      expect(sent.first.payload, parked.payload);
      expect(
        (await syncRepository.getOperationsForHousehold(
          'local-2',
        )).single.state,
        'completed',
      );
    },
  );

  test(
    'dismissing a rejected update releases only the next operation',
    () async {
      await _insertHousehold(database, 'local-1', serverId: 'hh-0004');
      await _insertHousehold(database, 'local-2', serverId: 'hh-0005');
      final rejected = _operation(
        opId: 'op-rejected',
        householdId: 'local-1',
        type: 'update',
        seq: 1,
        recordId: 'hh-0004',
        state: 'rejected',
        lastError: 'head name is empty',
        createdAt: DateTime.utc(2026, 11, 27, 10),
      );
      final next = _operation(
        opId: 'op-next',
        householdId: 'local-1',
        type: 'update',
        seq: 2,
        recordId: 'hh-0004',
        state: 'blocked',
        createdAt: DateTime.utc(2026, 11, 27, 10, 1),
      );
      final after = _operation(
        opId: 'op-after',
        householdId: 'local-1',
        type: 'update',
        seq: 3,
        recordId: 'hh-0004',
        state: 'blocked',
        createdAt: DateTime.utc(2026, 11, 27, 10, 2),
      );
      final other = _operation(
        opId: 'op-other',
        householdId: 'local-2',
        type: 'update',
        recordId: 'hh-0005',
        state: 'pending',
        createdAt: DateTime.utc(2026, 11, 27, 10, 3),
      );
      await _insertOperation(database, rejected);
      await _insertOperation(database, next);
      await _insertOperation(database, after);
      await _insertOperation(database, other);

      await syncRepository.dismissRejectedOperation(rejected.opId);

      final saved = await syncRepository.getOperationsForHousehold('local-1');
      expect(saved.map((operation) => operation.opId), ['op-next', 'op-after']);
      expect(saved.map((operation) => operation.state), ['pending', 'blocked']);
      expect(saved.first.payload, next.payload);
      expect(saved.first.seq, 2);
      expect(
        (await householdRepository.getHouseholdById('local-1'))!.headName,
        'Asha Noor',
      );
      expect(
        (await syncRepository.getOperationsForHousehold(
          'local-2',
        )).single.state,
        'pending',
      );

      when(() => apiService.syncOperation(any())).thenAnswer((
        invocation,
      ) async {
        final operation =
            invocation.positionalArguments.single as SyncOperation;
        if (operation.opId == 'op-next') {
          final current = await syncRepository.getOperationsForHousehold(
            'local-1',
          );
          expect(current.last.state, 'blocked');
        }
        return SyncResult(
          opId: operation.opId,
          status: SyncResultStatus.applied,
        );
      });

      await engine.syncPendingOperations();

      final sent = verify(
        () => apiService.syncOperation(captureAny()),
      ).captured.cast<SyncOperation>();
      expect(sent.map((operation) => operation.opId), [
        'op-next',
        'op-after',
        'op-other',
      ]);
      expect(
        sent.map((operation) => operation.opId),
        isNot(contains('op-rejected')),
      );
    },
  );
}

AppLogger _recordingLogger(List<LogEntry> logs) {
  return AppLogger(
    clock: () => DateTime.utc(2026, 11, 27, 12),
    write: logs.add,
  );
}

SyncEngine _loggedEngine({
  required ApiService apiService,
  required SyncRepository syncRepository,
  required HouseholdRepository householdRepository,
  required SettingsRepository settings,
  required List<LogEntry> logs,
}) {
  return SyncEngine(
    apiService: apiService,
    syncRepository: syncRepository,
    householdRepository: householdRepository,
    settingsRepository: settings,
    retryPolicy: RetryPolicy(random: () => 0.5),
    logger: _recordingLogger(logs),
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
    recordId: recordId,
    type: type,
    seq: seq,
    payload:
        payload ??
        const {
          'head_name': 'Asha Noor',
          'member_count': 4,
          'settlement': 'Kibera North',
        },
    state: state,
    attemptCount: attemptCount,
    nextRetryAt: nextRetryAt,
    lastError: lastError,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 27, 10),
  );
}

SyncOperation _copyState(SyncOperation operation, String state) {
  return SyncOperation(
    opId: operation.opId,
    householdId: operation.householdId,
    recordId: operation.recordId,
    type: operation.type,
    seq: operation.seq,
    payload: operation.payload,
    state: state,
    attemptCount: operation.attemptCount,
    nextRetryAt: operation.nextRetryAt,
    lastError: operation.lastError,
    createdAt: operation.createdAt,
  );
}
