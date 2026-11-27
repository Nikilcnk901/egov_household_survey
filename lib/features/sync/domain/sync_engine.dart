import '../../../core/logging/app_logger.dart';
import '../../../core/network/api_service.dart';
import '../../../core/settings/settings_repository.dart';
import '../../households/data/household_repository.dart';
import '../data/sync_repository.dart';
import 'retry_policy.dart';
import 'sync_operation.dart';

class SyncEngine {
  SyncEngine({
    ApiService? apiService,
    SyncRepository? syncRepository,
    HouseholdRepository? householdRepository,
    SettingsRepository? settingsRepository,
    RetryPolicy? retryPolicy,
    AppLogger? logger,
  }) : _apiService =
           apiService ??
           ApiService(baseUrl: HouseholdRepository.defaultBaseUrl),
       _syncRepository = syncRepository ?? SyncRepository(),
       _householdRepository = householdRepository ?? HouseholdRepository(),
       _settingsRepository = settingsRepository ?? SettingsRepository(),
       _retryPolicy = retryPolicy ?? RetryPolicy(),
       _logger = logger ?? AppLogger();

  final ApiService _apiService;
  final SyncRepository _syncRepository;
  final HouseholdRepository _householdRepository;
  final SettingsRepository _settingsRepository;
  final RetryPolicy _retryPolicy;
  final AppLogger _logger;
  final _SyncTotals _totals = _SyncTotals();
  Future<void>? _inFlight;

  Future<void> syncPendingOperations() {
    final inFlight = _inFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final run = _syncPendingOperations();
    _inFlight = run;
    return run.whenComplete(() {
      _inFlight = null;
      _totals.reset();
    });
  }

  Future<void> _syncPendingOperations() async {
    final startedAt = DateTime.now().toUtc();
    _logger.info(LogCategory.sync, '[SYNC START]');
    _logger.info(LogCategory.sync, 'Sync started');
    SyncOperation? current;
    final attempted = <String>{};
    try {
      await _syncRepository.reconcileBlockedOperations();
      final initial = await _syncRepository.getAllPendingOperations();
      _totals.discovered = initial.length;
      _logQueueSummary(initial);

      final online = await _settingsRepository.isOnline();
      if (!online) {
        _logger.info(
          LogCategory.sync,
          'Online/offline check: offline, returning without network requests',
        );
        return;
      }
      _logger.info(
        LogCategory.sync,
        'Online/offline check: online, continuing sync',
      );

      while (true) {
        final pending = await _syncRepository.getAllPendingOperations();
        _logger.info(LogCategory.queue, _discoveredMessage(pending));
        final ready = await _syncRepository.getReadyOperations(
          now: DateTime.now().toUtc(),
        );
        final operation = await _selectSendable([
          for (final candidate in ready)
            if (!attempted.contains(candidate.opId)) candidate,
        ]);
        if (operation == null) {
          return;
        }
        attempted.add(operation.opId);
        current = operation;
        _logger.info(
          LogCategory.sync,
          'Selected ${operation.type} operation at seq ${operation.seq}',
          operationId: operation.opId,
          householdId: operation.householdId,
          serverId: operation.recordId,
        );
        await _send(operation);
        current = null;
      }
    } catch (error, stackTrace) {
      if (current != null) {
        _totals.failed += 1;
      }
      _logger.error(
        LogCategory.sync,
        error is ApiException ? 'API request failed' : 'Sync failed',
        operationId: current?.opId,
        householdId: current?.householdId,
        serverId: current?.recordId,
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      await _logFinalSummary(startedAt);
      _logger.info(LogCategory.sync, 'Sync finished');
    }
  }

  Future<SyncOperation?> _selectSendable(List<SyncOperation> pending) async {
    for (final operation in pending) {
      final earliest = await _syncRepository.getNextOperationForHousehold(
        operation.householdId,
      );
      if (earliest?.opId == operation.opId) {
        return operation;
      }
    }
    return null;
  }

  String _discoveredMessage(List<SyncOperation> pending) {
    final pendingCount = pending
        .where((operation) => operation.state == 'pending')
        .length;
    final retryingCount = pending
        .where((operation) => operation.state == 'retrying')
        .length;
    final summary =
        'Discovered $pendingCount pending and $retryingCount retrying operations';
    if (pending.isEmpty) {
      return summary;
    }
    final details = pending
        .map(
          (operation) =>
              '${operation.opId} household ${operation.householdId} '
              '${operation.state} seq ${operation.seq}',
        )
        .join(', ');
    return '$summary: $details';
  }

  Future<void> _send(SyncOperation operation) async {
    _totals.sent += 1;
    _totals.households.add(operation.householdId);
    _logger.info(
      LogCategory.api,
      'Sending ${operation.type} request',
      operationId: operation.opId,
      householdId: operation.householdId,
      serverId: operation.recordId,
    );
    _logger.info(
      LogCategory.api,
      '[REQUEST: operation ${_totals.sent}/${_totals.discovered}]\n'
      'type=${operation.type.toUpperCase()}\n'
      'seq=${operation.seq}\n'
      'sending to the server',
      operationId: operation.opId,
      householdId: operation.householdId,
      serverId: operation.recordId,
    );
    final SyncResult result;
    try {
      result = await _apiService.syncOperation(operation);
    } on TransportException catch (error, stackTrace) {
      await _scheduleRetry(
        operation,
        reason: error.message,
        error: error,
        stackTrace: stackTrace,
      );
      return;
    } on ApiException catch (error, stackTrace) {
      if (_isRetryableStatus(error.statusCode)) {
        await _scheduleRetry(
          operation,
          reason: 'HTTP ${error.statusCode}: ${error.message}',
          error: error,
          stackTrace: stackTrace,
          retryAfter: error.statusCode == 503 ? error.retryAfter : null,
        );
        return;
      }
      if (_isPermanentClientError(error.statusCode)) {
        final reason = 'HTTP ${error.statusCode}: ${error.message}';
        await _syncRepository.parkOperation(
          _withState(
            operation,
            'parked',
            lastError: reason,
            clearNextRetryAt: true,
          ),
        );
        _totals.failed += 1;
        _logger.error(
          LogCategory.sync,
          '[RETRY]\n'
          'not retrying\n'
          'attempt=${operation.attemptCount}\n'
          'reason=$reason',
          operationId: operation.opId,
          householdId: operation.householdId,
          serverId: operation.recordId,
          error: error,
          stackTrace: stackTrace,
        );
        _logOutcome(
          operation,
          'Operation marked parked: $reason',
          serverId: operation.recordId,
        );
        return;
      }
      if (error.statusCode != null) {
        _logger.error(
          LogCategory.sync,
          '[RETRY]\n'
          'not retrying\n'
          'attempt=${operation.attemptCount}\n'
          'reason=HTTP ${error.statusCode}: ${error.message}',
          operationId: operation.opId,
          householdId: operation.householdId,
          serverId: operation.recordId,
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }
      rethrow;
    }
    _logger.info(
      LogCategory.api,
      'API response ${result.status.name}',
      operationId: operation.opId,
      householdId: operation.householdId,
      serverId: result.serverHouseholdId ?? operation.recordId,
    );
    switch (result.status) {
      case SyncResultStatus.applied:
      case SyncResultStatus.stale:
        await _complete(operation, result);
        _totals.record(result.status);
      case SyncResultStatus.duplicate:
        if (_isRejectedCreateDuplicate(operation, result)) {
          await _reject(operation, result.error);
          _totals.record(SyncResultStatus.rejected);
        } else {
          await _complete(operation, result);
          _totals.record(result.status);
        }
      case SyncResultStatus.rejected:
        await _reject(operation, result.error);
        _totals.record(result.status);
    }
    final outcome =
        result.status == SyncResultStatus.rejected ||
            _isRejectedCreateDuplicate(operation, result)
        ? 'rejected'
        : 'completed';
    final errorLine = result.error == null ? '' : '\nerror=${result.error}';
    _logger.info(
      LogCategory.sync,
      '[RESPONSE: ${result.status.name}]\n'
      'outcome=$outcome$errorLine',
      operationId: operation.opId,
      householdId: operation.householdId,
      serverId: result.serverHouseholdId ?? operation.recordId,
    );
  }

  void _logQueueSummary(List<SyncOperation> operations) {
    final pending = operations
        .where((operation) => operation.state == 'pending')
        .length;
    final retrying = operations
        .where((operation) => operation.state == 'retrying')
        .length;
    final grouped = <String, List<SyncOperation>>{};
    for (final operation in operations) {
      grouped.putIfAbsent(operation.householdId, () => []).add(operation);
    }

    final lines = StringBuffer('[QUEUE SUMMARY]\n');
    lines.writeln('pending=$pending');
    lines.writeln('retrying=$retrying');
    lines.writeln('households=${grouped.length}');
    for (final entry in grouped.entries) {
      final ordered = [...entry.value]
        ..sort((left, right) => left.seq.compareTo(right.seq));
      lines.writeln('[HOUSEHOLD: ${entry.key}]');
      for (final operation in ordered) {
        lines.writeln(
          '${operation.type.toUpperCase()} seq ${operation.seq} '
          'op=${operation.opId}',
        );
      }
    }
    _logger.info(LogCategory.queue, lines.toString().trimRight());
  }

  Future<void> _logFinalSummary(DateTime startedAt) async {
    var stillPending = '0';
    try {
      stillPending = (await _syncRepository.getAllPendingOperations()).length
          .toString();
    } catch (error, stackTrace) {
      stillPending = 'unavailable';
      _logger.error(
        LogCategory.sync,
        'Pending count unavailable for sync summary',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final duration = DateTime.now().toUtc().difference(startedAt);
    _logger.info(
      LogCategory.sync,
      '[SYNC SUMMARY]\n'
      'discovered=${_totals.discovered}\n'
      'applied=${_totals.applied}\n'
      'duplicate=${_totals.duplicate}\n'
      'stale=${_totals.stale}\n'
      'rejected=${_totals.rejected}\n'
      'failed=${_totals.failed}\n'
      'pending=$stillPending\n'
      'households=${_totals.households.length}\n'
      'duration=${duration.inMilliseconds}ms',
    );
  }

  bool _isRetryableStatus(int? statusCode) {
    if (statusCode == null) {
      return false;
    }
    return statusCode == 408 ||
        statusCode == 429 ||
        (statusCode >= 500 && statusCode <= 599);
  }

  bool _isPermanentClientError(int? statusCode) {
    if (statusCode == null) {
      return false;
    }
    return statusCode >= 400 &&
        statusCode <= 499 &&
        statusCode != 408 &&
        statusCode != 429;
  }

  Future<void> _scheduleRetry(
    SyncOperation operation, {
    required String reason,
    required Object error,
    required StackTrace stackTrace,
    Duration? retryAfter,
  }) async {
    if (!_retryPolicy.allowsRetry(operation.attemptCount)) {
      await _syncRepository.parkOperation(
        _withState(
          operation,
          'parked',
          lastError: reason,
          nextRetryAt: null,
          clearNextRetryAt: true,
        ),
      );
      _totals.failed += 1;
      _logger.error(
        LogCategory.sync,
        '[RETRY]\n'
        'attempt=${operation.attemptCount}\n'
        'limit exhausted\n'
        'reason=$reason',
        operationId: operation.opId,
        householdId: operation.householdId,
        serverId: operation.recordId,
        error: error,
        stackTrace: stackTrace,
      );
      _logOutcome(
        operation,
        'Operation marked parked: $reason',
        serverId: operation.recordId,
      );
      return;
    }

    final delay = _retryPolicy.nextDelay(
      attemptCount: operation.attemptCount,
      retryAfter: retryAfter,
    );
    final nextAttempt = operation.attemptCount + 1;
    final nextRetryAt = DateTime.now().toUtc().add(delay);
    await _syncRepository.saveRetryState(
      _withState(
        operation,
        'retrying',
        attemptCount: nextAttempt,
        nextRetryAt: nextRetryAt,
        lastError: reason,
      ),
    );
    _logger.warning(
      LogCategory.sync,
      '[RETRY]\n'
      'attempt=$nextAttempt\n'
      'next_retry_at=${nextRetryAt.toIso8601String()}\n'
      'reason=$reason',
      operationId: operation.opId,
      householdId: operation.householdId,
      serverId: operation.recordId,
    );
  }

  /// A duplicate create that repeats a validation error has no server ID.
  /// It cannot be completed, and sending it again would fail the same way.
  bool _isRejectedCreateDuplicate(SyncOperation operation, SyncResult result) {
    final serverId = result.serverHouseholdId;
    final error = result.error;
    return operation.type == 'create' &&
        result.status == SyncResultStatus.duplicate &&
        (serverId == null || serverId.isEmpty) &&
        error != null &&
        error.isNotEmpty;
  }

  Future<void> _complete(SyncOperation operation, SyncResult result) async {
    if (operation.type == 'create') {
      final serverId = result.serverHouseholdId;
      if (serverId == null || serverId.isEmpty) {
        throw StateError(
          'Create operation ${operation.opId} completed without a server id',
        );
      }
      _logger.info(
        LogCategory.household,
        'Mapping create operation to server id',
        operationId: operation.opId,
        householdId: operation.householdId,
        serverId: serverId,
      );
      await _householdRepository.completeCreateOperation(
        opId: operation.opId,
        householdId: operation.householdId,
        serverId: serverId,
      );
      _logOutcome(operation, 'Operation marked completed', serverId: serverId);
      return;
    }

    await _syncRepository.completeOperation(_withState(operation, 'completed'));
    _logOutcome(
      operation,
      'Operation marked completed',
      serverId: operation.recordId,
    );
  }

  Future<void> _reject(SyncOperation operation, String? error) async {
    await _syncRepository.rejectOperation(
      _withState(
        operation,
        'rejected',
        lastError: error,
        clearNextRetryAt: true,
      ),
    );
    final detail = error == null
        ? 'Operation marked rejected'
        : 'Operation marked rejected: $error';
    _logOutcome(operation, detail, serverId: operation.recordId);
  }

  void _logOutcome(
    SyncOperation operation,
    String message, {
    String? serverId,
  }) {
    _logger.info(
      LogCategory.sync,
      message,
      operationId: operation.opId,
      householdId: operation.householdId,
      serverId: serverId,
    );
  }

  SyncOperation _withState(
    SyncOperation operation,
    String state, {
    String? lastError,
    int? attemptCount,
    DateTime? nextRetryAt,
    bool clearNextRetryAt = false,
  }) {
    return SyncOperation(
      opId: operation.opId,
      householdId: operation.householdId,
      recordId: operation.recordId,
      type: operation.type,
      seq: operation.seq,
      payload: operation.payload,
      state: state,
      attemptCount: attemptCount ?? operation.attemptCount,
      nextRetryAt: clearNextRetryAt
          ? null
          : nextRetryAt ?? operation.nextRetryAt,
      lastError: lastError ?? operation.lastError,
      createdAt: operation.createdAt,
    );
  }
}

class _SyncTotals {
  var discovered = 0;
  var applied = 0;
  var duplicate = 0;
  var stale = 0;
  var rejected = 0;
  var failed = 0;
  var sent = 0;
  final households = <String>{};

  void record(SyncResultStatus status) {
    switch (status) {
      case SyncResultStatus.applied:
        applied += 1;
      case SyncResultStatus.duplicate:
        duplicate += 1;
      case SyncResultStatus.stale:
        stale += 1;
      case SyncResultStatus.rejected:
        rejected += 1;
    }
  }

  void reset() {
    discovered = 0;
    applied = 0;
    duplicate = 0;
    stale = 0;
    rejected = 0;
    failed = 0;
    sent = 0;
    households.clear();
  }
}
