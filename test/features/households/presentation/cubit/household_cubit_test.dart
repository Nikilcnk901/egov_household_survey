import 'package:egov_household_survey/core/logging/app_logger.dart';
import 'package:egov_household_survey/core/settings/settings_repository.dart';
import 'package:egov_household_survey/features/households/data/household_repository.dart';
import 'package:egov_household_survey/features/households/domain/household.dart';
import 'package:egov_household_survey/features/households/presentation/cubit/household_cubit.dart';
import 'package:egov_household_survey/features/households/presentation/cubit/household_state.dart';
import 'package:egov_household_survey/features/sync/data/sync_repository.dart';
import 'package:egov_household_survey/features/sync/domain/sync_engine.dart';
import 'package:egov_household_survey/features/sync/domain/sync_operation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockSettingsRepository extends Mock implements SettingsRepository {}

class _MockSyncRepository extends Mock implements SyncRepository {}

class _MockSyncEngine extends Mock implements SyncEngine {}

void main() {
  late _MockHouseholdRepository repository;
  late _MockSettingsRepository settings;
  late _MockSyncRepository syncRepository;
  late _MockSyncEngine syncEngine;
  late List<LogEntry> logs;
  late HouseholdCubit cubit;
  late List<Household> stored;

  setUpAll(() {
    registerFallbackValue(
      Household(
        id: 'fallback',
        headName: 'Fallback',
        memberCount: 1,
        settlement: 'Fallback',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
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

  setUp(() {
    repository = _MockHouseholdRepository();
    settings = _MockSettingsRepository();
    syncRepository = _MockSyncRepository();
    syncEngine = _MockSyncEngine();
    logs = [];
    stored = [];
    when(() => settings.setOnline(any())).thenAnswer((_) async {});
    when(
      () => repository.getHouseholds(),
    ).thenAnswer((_) async => stored.toList());
    when(() => repository.fetchInitialHouseholds()).thenAnswer((_) async {});
    when(
      () => syncRepository.reconcileBlockedOperations(),
    ).thenAnswer((_) async {});
    when(
      () => syncRepository.getAllOperations(),
    ).thenAnswer((_) async => const []);
    when(() => syncEngine.syncPendingOperations()).thenAnswer((_) async {});
    cubit = HouseholdCubit(
      householdRepository: repository,
      settingsRepository: settings,
      syncRepository: syncRepository,
      syncEngine: syncEngine,
      logger: AppLogger(
        clock: () => DateTime.utc(2026, 11, 27, 12),
        write: logs.add,
      ),
    );
  });

  tearDown(() async {
    await cubit.close();
  });

  test('offline mode does not call the API', () async {
    when(() => settings.isOnline()).thenAnswer((_) async => false);

    await cubit.loadHouseholds();
    await cubit.setOnline(false);

    expect(cubit.state.isOnline, isFalse);
    expect(cubit.state, isA<HouseholdLoaded>());
    verifyNever(() => repository.fetchInitialHouseholds());
  });

  test('switching online loads server households once', () async {
    when(() => settings.isOnline()).thenAnswer((_) async => false);
    stored.add(_household());

    await cubit.loadHouseholds();
    verifyNever(() => repository.fetchInitialHouseholds());

    await cubit.setOnline(true);
    await cubit.setOnline(true);

    expect(cubit.state.isOnline, isTrue);
    final state = cubit.state as HouseholdLoaded;
    expect(state.households.single.headName, 'Amina Wanjiru');
    verify(() => settings.setOnline(true)).called(2);
    verify(() => repository.fetchInitialHouseholds()).called(1);
  });

  test('concurrent online switches share one initial fetch', () async {
    when(() => settings.isOnline()).thenAnswer((_) async => true);
    when(() => repository.fetchInitialHouseholds()).thenAnswer((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });

    await Future.wait([cubit.setOnline(true), cubit.setOnline(true)]);

    verify(() => repository.fetchInitialHouseholds()).called(1);
  });

  test('creating a household keeps the current mode', () async {
    when(() => settings.isOnline()).thenAnswer((_) async => false);
    when(
      () => repository.createHouseholdWithOperation(any(), any()),
    ).thenAnswer((invocation) async {
      stored.add(invocation.positionalArguments[0] as Household);
    });

    await cubit.loadHouseholds();
    await cubit.createHousehold(
      headName: 'Asha Noor',
      memberCount: 3,
      settlement: 'Mathare Valley',
    );

    expect(cubit.state.isOnline, isFalse);
    expect(
      (cubit.state as HouseholdLoaded).households.single.headName,
      'Asha Noor',
    );
    verifyNever(() => repository.fetchInitialHouseholds());
  });

  test('manual sync refreshes queue status from the database', () async {
    when(() => settings.isOnline()).thenAnswer((_) async => true);
    stored.add(_household());
    when(
      () => syncRepository.getAllOperations(),
    ).thenAnswer((_) async => [_operation(state: 'retrying', attemptCount: 2)]);

    await cubit.loadHouseholds();

    final before = cubit.state as HouseholdLoaded;
    expect(before.syncStatus.retrying, 1);
    expect(before.syncStatus.households.single.status, 'retrying');
    expect(before.syncStatus.households.single.serverId, 'hh-0001');
    expect(
      before.syncStatus.households.single.operations.single.attemptCount,
      2,
    );

    when(() => syncEngine.syncPendingOperations()).thenAnswer((_) async {
      when(() => syncRepository.getAllOperations()).thenAnswer(
        (_) async => [
          _operation(
            state: 'completed',
            attemptCount: 2,
            lastError: 'timed out',
          ),
        ],
      );
    });

    await cubit.syncNow();

    verify(() => syncEngine.syncPendingOperations()).called(1);
    final after = cubit.state as HouseholdLoaded;
    expect(after.households.single.headName, 'Amina Wanjiru');
    expect(after.syncStatus.retrying, 0);
    expect(after.syncStatus.completed, 1);
    expect(after.syncStatus.households.single.status, 'completed');
    expect(
      after.syncStatus.households.single.operations.single.lastError,
      'timed out',
    );
    expect(
      logs.map((entry) => entry.message),
      contains('Manual sync requested'),
    );
    expect(logs.single.category, LogCategory.app);
  });

  test('retry resets a parked operation and starts sync', () async {
    when(() => settings.isOnline()).thenAnswer((_) async => true);
    stored.add(_household());
    when(() => syncRepository.getAllOperations()).thenAnswer(
      (_) async => [
        _operation(state: 'parked', attemptCount: 5, lastError: 'timed out'),
        _operation(opId: 'op-later', seq: 3, state: 'blocked'),
      ],
    );
    when(() => syncRepository.retryParkedOperation('op-1')).thenAnswer((
      _,
    ) async {
      when(() => syncRepository.getAllOperations()).thenAnswer(
        (_) async => [
          _operation(state: 'pending'),
          _operation(opId: 'op-later', seq: 3, state: 'blocked'),
        ],
      );
    });

    await cubit.loadHouseholds();
    await cubit.retryParkedOperation(
      _operation(state: 'parked', attemptCount: 5, lastError: 'timed out'),
    );

    verify(() => syncRepository.retryParkedOperation('op-1')).called(1);
    verify(() => syncEngine.syncPendingOperations()).called(1);
    final loaded = cubit.state as HouseholdLoaded;
    expect(loaded.syncStatus.parked, 0);
    expect(loaded.syncStatus.pending, 1);
    expect(loaded.syncStatus.blocked, 1);
    expect(loaded.syncStatus.households.single.status, 'pending');
    expect(
      loaded.syncStatus.households.single.operations.last.state,
      'blocked',
    );
  });

  test('dismiss removes a rejected update and refreshes the queue', () async {
    when(() => settings.isOnline()).thenAnswer((_) async => true);
    stored.add(_household());
    when(() => syncRepository.getAllOperations()).thenAnswer(
      (_) async => [
        _operation(
          opId: 'op-rejected',
          state: 'rejected',
          lastError: 'invalid',
        ),
        _operation(opId: 'op-next', seq: 3, state: 'blocked'),
      ],
    );
    when(
      () => syncRepository.dismissRejectedOperation('op-rejected'),
    ).thenAnswer((_) async {
      when(() => syncRepository.getAllOperations()).thenAnswer(
        (_) async => [_operation(opId: 'op-next', seq: 3, state: 'pending')],
      );
    });

    await cubit.loadHouseholds();
    await cubit.dismissRejectedOperation(
      _operation(opId: 'op-rejected', state: 'rejected', lastError: 'invalid'),
    );

    verify(
      () => syncRepository.dismissRejectedOperation('op-rejected'),
    ).called(1);
    verifyNever(() => syncEngine.syncPendingOperations());
    final loaded = cubit.state as HouseholdLoaded;
    expect(loaded.syncStatus.rejected, 0);
    expect(loaded.syncStatus.pending, 1);
    expect(loaded.syncStatus.blocked, 0);
    expect(loaded.syncStatus.households.single.status, 'pending');
    expect(loaded.households, hasLength(1));
  });
}

SyncOperation _operation({
  String opId = 'op-1',
  int seq = 2,
  required String state,
  int attemptCount = 0,
  String? lastError,
}) {
  return SyncOperation(
    opId: opId,
    householdId: 'hh-0001',
    recordId: 'hh-0001',
    type: 'update',
    seq: seq,
    payload: const {'member_count': 5},
    state: state,
    attemptCount: attemptCount,
    lastError: lastError,
    createdAt: DateTime.utc(2026, 11, 27, 10),
  );
}

Household _household() {
  final updatedAt = DateTime.utc(2026, 11, 26, 12);
  return Household(
    id: 'hh-0001',
    serverId: 'hh-0001',
    headName: 'Amina Wanjiru',
    memberCount: 4,
    settlement: 'Kibera North',
    createdAt: updatedAt,
    updatedAt: updatedAt,
  );
}
