import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/logging/app_logger.dart';
import '../../../../core/settings/settings_repository.dart';
import '../../../sync/data/sync_repository.dart';
import '../../../sync/domain/sync_engine.dart';
import '../../../sync/domain/sync_operation.dart';
import '../../../sync/domain/sync_queue_summary.dart';
import '../../data/household_repository.dart';
import '../../domain/household.dart';
import 'household_state.dart';

class HouseholdCubit extends Cubit<HouseholdState> {
  final HouseholdRepository _householdRepository;
  final SettingsRepository _settingsRepository;
  final SyncRepository _syncRepository;
  final SyncEngine _syncEngine;
  final AppLogger _logger;
  final Uuid _uuid;
  Future<void>? _initialFetch;

  HouseholdCubit({
    HouseholdRepository? householdRepository,
    SettingsRepository? settingsRepository,
    SyncRepository? syncRepository,
    SyncEngine? syncEngine,
    AppLogger? logger,
    Uuid? uuid,
  }) : _householdRepository = householdRepository ?? HouseholdRepository(),
       _settingsRepository = settingsRepository ?? SettingsRepository(),
       _syncRepository = syncRepository ?? SyncRepository(),
       _syncEngine = syncEngine ?? SyncEngine(),
       _logger = logger ?? AppLogger(),
       _uuid = uuid ?? const Uuid(),
       super(const HouseholdInitial());

  Future<void> loadHouseholds() async {
    var online = state.isOnline;
    emit(HouseholdLoading(isOnline: online));

    try {
      online = await _settingsRepository.isOnline();
      if (online) {
        await _loadInitialHouseholdsOnce();
      }
      await _emitHouseholds(online);
    } catch (error) {
      emit(HouseholdError(error.toString(), isOnline: online));
    }
  }

  Future<void> setOnline(bool online) async {
    await _settingsRepository.setOnline(online);
    if (!online) {
      emit(_withOnline(false));
      return;
    }

    try {
      await _loadInitialHouseholdsOnce();
      await _emitHouseholds(true);
    } catch (error) {
      emit(HouseholdError(error.toString(), isOnline: true));
    }
  }

  Future<void> retryParkedOperation(SyncOperation operation) async {
    _logger.info(
      LogCategory.app,
      'Retry requested',
      operationId: operation.opId,
      householdId: operation.householdId,
    );
    try {
      await _syncRepository.retryParkedOperation(operation.opId);
      try {
        await _syncEngine.syncPendingOperations();
      } catch (error, stackTrace) {
        _logger.error(
          LogCategory.app,
          'Retry sync failed',
          operationId: operation.opId,
          householdId: operation.householdId,
          error: error,
          stackTrace: stackTrace,
        );
      }
      final online = await _settingsRepository.isOnline();
      await _emitHouseholds(online);
    } catch (error) {
      emit(HouseholdError(error.toString(), isOnline: state.isOnline));
    }
  }

  Future<void> dismissRejectedOperation(SyncOperation operation) async {
    _logger.info(
      LogCategory.app,
      'Dismiss requested',
      operationId: operation.opId,
      householdId: operation.householdId,
    );
    try {
      await _syncRepository.dismissRejectedOperation(operation.opId);
      final online = await _settingsRepository.isOnline();
      await _emitHouseholds(online);
    } catch (error) {
      emit(HouseholdError(error.toString(), isOnline: state.isOnline));
    }
  }

  Future<void> syncNow() async {
    _logger.info(LogCategory.app, 'Manual sync requested');
    try {
      await _syncEngine.syncPendingOperations();
    } catch (error, stackTrace) {
      _logger.error(
        LogCategory.app,
        'Manual sync failed',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      final online = await _settingsRepository.isOnline();
      await _emitHouseholds(online);
    } catch (error) {
      emit(HouseholdError(error.toString(), isOnline: state.isOnline));
    }
  }

  Future<void> _loadInitialHouseholdsOnce() {
    final inFlight = _initialFetch;
    if (inFlight != null) {
      return inFlight;
    }

    final fetch = _householdRepository.fetchInitialHouseholds().then(
      (value) => value,
      onError: (Object error, StackTrace stackTrace) {
        _initialFetch = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _initialFetch = fetch;
    return fetch;
  }

  HouseholdState _withOnline(bool online) {
    return switch (state) {
      HouseholdInitial() => HouseholdInitial(isOnline: online),
      HouseholdLoading() => HouseholdLoading(isOnline: online),
      HouseholdLoaded(:final households, :final syncStatus) => HouseholdLoaded(
        households,
        syncStatus: syncStatus,
        isOnline: online,
      ),
      HouseholdError(:final message) => HouseholdError(
        message,
        isOnline: online,
      ),
    };
  }

  Future<void> createHousehold({
    required String headName,
    required int memberCount,
    required String settlement,
  }) async {
    try {
      final now = DateTime.now().toUtc();
      final householdId = _uuid.v4();
      final household = Household(
        id: householdId,
        headName: headName,
        memberCount: memberCount,
        settlement: settlement,
        lastSeq: 1,
        createdAt: now,
        updatedAt: now,
      );
      final operation = SyncOperation(
        opId: _uuid.v4(),
        householdId: householdId,
        recordId: null,
        type: 'create',
        seq: 1,
        payload: {
          'head_name': headName,
          'member_count': memberCount,
          'settlement': settlement,
        },
        createdAt: now,
      );

      await _householdRepository.createHouseholdWithOperation(
        household,
        operation,
      );

      await _emitHouseholds(state.isOnline);
    } catch (error) {
      emit(HouseholdError(error.toString(), isOnline: state.isOnline));
    }
  }

  Future<void> updateHousehold(Household household) async {
    try {
      await _householdRepository.updateHouseholdWithOperation(
        id: household.id,
        headName: household.headName,
        memberCount: household.memberCount,
        settlement: household.settlement,
        opId: _uuid.v4(),
      );

      await _emitHouseholds(state.isOnline);
    } catch (error) {
      emit(HouseholdError(error.toString(), isOnline: state.isOnline));
    }
  }

  Future<void> _emitHouseholds(bool online) async {
    final households = await _householdRepository.getHouseholds();
    await _syncRepository.reconcileBlockedOperations();
    final operations = await _syncRepository.getAllOperations();
    emit(
      HouseholdLoaded(
        households,
        syncStatus: SyncQueueSummary.from(households, operations),
        isOnline: online,
      ),
    );
  }
}
