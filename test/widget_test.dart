import 'package:egov_household_survey/core/settings/settings_repository.dart';
import 'package:egov_household_survey/features/households/data/household_repository.dart';
import 'package:egov_household_survey/features/households/domain/household.dart';
import 'package:egov_household_survey/features/households/presentation/cubit/household_cubit.dart';
import 'package:egov_household_survey/features/sync/data/sync_repository.dart';
import 'package:egov_household_survey/features/sync/domain/sync_engine.dart';
import 'package:egov_household_survey/features/sync/domain/sync_operation.dart';
import 'package:egov_household_survey/main.dart';
import 'package:flutter/material.dart';
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
    stored = [];
    when(() => settings.isOnline()).thenAnswer((_) async => true);
    when(() => settings.setOnline(any())).thenAnswer((_) async {});
    when(() => repository.fetchInitialHouseholds()).thenAnswer((_) async {});
    when(
      () => syncRepository.reconcileBlockedOperations(),
    ).thenAnswer((_) async {});
    when(
      () => syncRepository.getAllOperations(),
    ).thenAnswer((_) async => const []);
    when(() => syncEngine.syncPendingOperations()).thenAnswer((_) async {});
    when(
      () => repository.getHouseholds(),
    ).thenAnswer((_) async => stored.toList());
    when(
      () => repository.createHouseholdWithOperation(any(), any()),
    ).thenAnswer((invocation) async {
      stored.add(invocation.positionalArguments[0] as Household);
    });
    when(
      () => repository.updateHouseholdWithOperation(
        id: any(named: 'id'),
        headName: any(named: 'headName'),
        memberCount: any(named: 'memberCount'),
        settlement: any(named: 'settlement'),
        opId: any(named: 'opId'),
      ),
    ).thenAnswer((invocation) async {
      final id = invocation.namedArguments[#id] as String;
      final index = stored.indexWhere((household) => household.id == id);
      final current = stored[index];
      stored[index] = Household(
        id: current.id,
        serverId: current.serverId,
        headName: invocation.namedArguments[#headName] as String,
        memberCount: invocation.namedArguments[#memberCount] as int,
        settlement: invocation.namedArguments[#settlement] as String,
        lastSeq: current.lastSeq,
        createdAt: current.createdAt,
        updatedAt: current.updatedAt,
      );
    });
  });

  testWidgets('shows an empty household list', (tester) async {
    await _pumpApp(tester, repository, settings, syncRepository, syncEngine);

    expect(find.text('Households'), findsOneWidget);
    expect(find.text('No households yet'), findsOneWidget);
  });

  testWidgets('shows head name, member count and settlement', (tester) async {
    stored.add(_household());

    await _pumpApp(tester, repository, settings, syncRepository, syncEngine);

    expect(find.text('Amina Wanjiru'), findsOneWidget);
    expect(find.text('4 members'), findsOneWidget);
    expect(find.text('Kibera North'), findsOneWidget);
  });

  testWidgets('create form rejects empty fields and a member count of zero', (
    tester,
  ) async {
    await _pumpApp(tester, repository, settings, syncRepository, syncEngine);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Member count'),
      '0',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.text('Enter a head name'), findsOneWidget);
    expect(find.text('Enter a member count greater than zero'), findsOneWidget);
    expect(find.text('Enter a settlement'), findsOneWidget);
    verifyNever(() => repository.createHouseholdWithOperation(any(), any()));
  });

  testWidgets('saving a household shows it on the list', (tester) async {
    await _pumpApp(tester, repository, settings, syncRepository, syncEngine);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Head name'),
      'Asha Noor',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Member count'),
      '3',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Settlement'),
      'Mathare Valley',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Household saved'), findsOneWidget);
    expect(find.text('Asha Noor'), findsOneWidget);
    expect(find.text('3 members'), findsOneWidget);
    expect(find.text('Mathare Valley'), findsOneWidget);
  });

  testWidgets('editing a household updates the list', (tester) async {
    stored.add(_household());

    await _pumpApp(tester, repository, settings, syncRepository, syncEngine);
    expect(find.text('4 members'), findsOneWidget);
    expect(find.text('Kibera North'), findsOneWidget);
    expect(find.text('No operations'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('Edit household'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Head name'),
          )
          .controller!
          .text,
      'Amina Wanjiru',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Member count'),
          )
          .controller!
          .text,
      '4',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Settlement'),
          )
          .controller!
          .text,
      'Kibera North',
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Head name'),
      'Amina Wanjiru Updated',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Household updated'), findsOneWidget);
    expect(find.text('Amina Wanjiru Updated'), findsOneWidget);
    expect(find.text('Amina Wanjiru'), findsNothing);
    verify(
      () => repository.updateHouseholdWithOperation(
        id: 'hh-0001',
        headName: 'Amina Wanjiru Updated',
        memberCount: 4,
        settlement: 'Kibera North',
        opId: any(named: 'opId'),
      ),
    ).called(1);
  });

  testWidgets('Sync Now refreshes the queue status', (tester) async {
    stored.add(_household());
    var operations = [
      _operation(state: 'retrying', attemptCount: 2, lastError: 'timed out'),
    ];
    when(
      () => syncRepository.getAllOperations(),
    ).thenAnswer((_) async => operations);
    when(() => syncEngine.syncPendingOperations()).thenAnswer((_) async {
      operations = [_operation(state: 'completed', attemptCount: 2)];
    });

    await _pumpApp(tester, repository, settings, syncRepository, syncEngine);

    expect(find.text('Mode: Online'), findsOneWidget);
    expect(find.text('Sync Queue'), findsOneWidget);
    expect(find.text('1 operation'), findsOneWidget);
    expect(find.text('Amina Wanjiru'), findsOneWidget);
    expect(find.text('4 members'), findsOneWidget);
    expect(find.text('Kibera North'), findsOneWidget);
    expect(find.text('Retrying (1)'), findsOneWidget);
    expect(_queueCount(tester, 'pending'), '0');
    expect(_queueCount(tester, 'retrying'), '1');
    expect(_queueCount(tester, 'parked'), '0');
    expect(_queueCount(tester, 'completed'), '0');

    await tester.tap(find.byTooltip('Show operations'));
    await tester.pumpAndSettle();

    expect(find.text('Operations (1)'), findsOneWidget);
    expect(find.text('Update members'), findsOneWidget);
    expect(find.text('Seq: 2 · Attempts: 2'), findsOneWidget);
    expect(find.text('Retrying'), findsWidgets);
    expect(find.text('timed out'), findsOneWidget);
    expect(find.textContaining('Next:'), findsOneWidget);

    await tester.tap(find.text('Sync Now'));
    await tester.pumpAndSettle();

    verify(() => syncEngine.syncPendingOperations()).called(1);
    expect(_queueCount(tester, 'retrying'), '0');
    expect(_queueCount(tester, 'completed'), '1');
    expect(find.text('Completed'), findsWidgets);
    expect(find.text('Seq: 2 · Attempts: 2'), findsOneWidget);
    expect(find.text('timed out'), findsNothing);
    expect(find.text('Amina Wanjiru'), findsOneWidget);
  });

  testWidgets(
    'Retry and Dismiss update the queue without offering the other action',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      stored.add(_household());
      var operations = [
        _operation(
          opId: 'op-rejected',
          seq: 1,
          state: 'rejected',
          lastError: 'head name is empty',
        ),
        _operation(opId: 'op-blocked', seq: 2, state: 'blocked'),
        _operation(
          opId: 'op-parked',
          seq: 3,
          state: 'parked',
          attemptCount: 5,
          lastError: 'limit exhausted',
        ),
      ];
      when(
        () => syncRepository.getAllOperations(),
      ).thenAnswer((_) async => operations);
      when(
        () => syncRepository.dismissRejectedOperation('op-rejected'),
      ).thenAnswer((_) async {
        operations = [
          _operation(opId: 'op-blocked', seq: 2, state: 'pending'),
          _operation(
            opId: 'op-parked',
            seq: 3,
            state: 'parked',
            attemptCount: 5,
            lastError: 'limit exhausted',
          ),
        ];
      });
      when(() => syncRepository.retryParkedOperation('op-parked')).thenAnswer((
        _,
      ) async {
        operations = [
          _operation(opId: 'op-blocked', seq: 2, state: 'pending'),
          _operation(opId: 'op-parked', seq: 3, state: 'pending'),
        ];
      });

      await _pumpApp(tester, repository, settings, syncRepository, syncEngine);
      await tester.tap(find.byTooltip('Show operations'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('retry-op-parked')), findsOneWidget);
      expect(find.byKey(const Key('dismiss-op-parked')), findsNothing);
      expect(find.byKey(const Key('dismiss-op-rejected')), findsOneWidget);
      expect(find.byKey(const Key('retry-op-rejected')), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
      expect(
        find.text('An earlier operation must be resolved first.'),
        findsOneWidget,
      );
      expect(find.text('head name is empty'), findsOneWidget);
      expect(find.text('limit exhausted'), findsOneWidget);
      expect(
        find.text('Rejected (1) · Parked (1) · Blocked (1)'),
        findsOneWidget,
      );
      expect(_queueCount(tester, 'rejected'), '1');
      expect(_queueCount(tester, 'parked'), '1');
      expect(_queueCount(tester, 'blocked'), '1');
      expect(_queueCount(tester, 'pending'), '0');

      await tester.ensureVisible(find.byKey(const Key('dismiss-op-rejected')));
      await tester.tap(find.byKey(const Key('dismiss-op-rejected')));
      await tester.pumpAndSettle();

      expect(find.text('Dismiss'), findsNothing);
      expect(find.byKey(const Key('retry-op-parked')), findsOneWidget);
      expect(find.byKey(const Key('dismiss-op-parked')), findsNothing);
      expect(
        find.text('An earlier operation must be resolved first.'),
        findsNothing,
      );
      expect(find.text('Parked (1) · Pending (1)'), findsOneWidget);
      expect(_queueCount(tester, 'rejected'), '0');
      expect(_queueCount(tester, 'pending'), '1');
      expect(_queueCount(tester, 'blocked'), '0');
      expect(_queueCount(tester, 'parked'), '1');
      verifyNever(() => syncEngine.syncPendingOperations());

      await tester.ensureVisible(find.byKey(const Key('retry-op-parked')));
      await tester.tap(find.byKey(const Key('retry-op-parked')));
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsNothing);
      expect(find.text('Dismiss'), findsNothing);
      expect(find.text('Pending (2)'), findsOneWidget);
      expect(_queueCount(tester, 'parked'), '0');
      expect(_queueCount(tester, 'pending'), '2');
      expect(_queueCount(tester, 'rejected'), '0');
      verify(() => syncEngine.syncPendingOperations()).called(1);
      verify(() => syncRepository.retryParkedOperation('op-parked')).called(1);
      verify(
        () => syncRepository.dismissRejectedOperation('op-rejected'),
      ).called(1);
    },
  );
}

String _queueCount(WidgetTester tester, String state) {
  return tester.widget<Text>(find.byKey(Key('queue-$state'))).data!;
}

Future<void> _pumpApp(
  WidgetTester tester,
  HouseholdRepository repository,
  SettingsRepository settings,
  SyncRepository syncRepository,
  SyncEngine syncEngine,
) async {
  await tester.pumpWidget(
    HouseholdSurveyApp(
      householdCubit: HouseholdCubit(
        householdRepository: repository,
        settingsRepository: settings,
        syncRepository: syncRepository,
        syncEngine: syncEngine,
      ),
    ),
  );
  await tester.pumpAndSettle();
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
    nextRetryAt: state == 'retrying' ? DateTime.utc(2026, 11, 27, 8, 40) : null,
    lastError: lastError,
    createdAt: DateTime.utc(2026, 11, 27, 10),
  );
}

Household _household() {
  final createdAt = DateTime.utc(2026, 11, 26, 9);
  return Household(
    id: 'hh-0001',
    serverId: 'hh-0001',
    headName: 'Amina Wanjiru',
    memberCount: 4,
    settlement: 'Kibera North',
    lastSeq: 1,
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}
