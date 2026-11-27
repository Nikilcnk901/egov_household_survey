import 'package:equatable/equatable.dart';

import '../../households/domain/household.dart';
import 'sync_operation.dart';

class SyncQueueSummary extends Equatable {
  const SyncQueueSummary({
    required this.pending,
    required this.completed,
    required this.retrying,
    required this.parked,
    required this.blocked,
    required this.rejected,
    required this.households,
  });

  const SyncQueueSummary.empty()
    : pending = 0,
      completed = 0,
      retrying = 0,
      parked = 0,
      blocked = 0,
      rejected = 0,
      households = const [];

  factory SyncQueueSummary.from(
    List<Household> households,
    List<SyncOperation> operations,
  ) {
    final byHousehold = <String, List<SyncOperation>>{};
    for (final operation in operations) {
      byHousehold.putIfAbsent(operation.householdId, () => []).add(operation);
    }

    final rows = <HouseholdSyncStatus>[];
    final seen = <String>{};
    for (final household in households) {
      seen.add(household.id);
      rows.add(
        HouseholdSyncStatus.fromOperations(
          householdId: household.id,
          serverId: household.serverId,
          operations: byHousehold[household.id] ?? const [],
        ),
      );
    }

    for (final entry in byHousehold.entries) {
      if (seen.contains(entry.key)) {
        continue;
      }
      String? serverId;
      for (final operation in entry.value) {
        if (operation.recordId != null) {
          serverId = operation.recordId;
          break;
        }
      }
      rows.add(
        HouseholdSyncStatus.fromOperations(
          householdId: entry.key,
          serverId: serverId,
          operations: entry.value,
        ),
      );
    }

    return SyncQueueSummary(
      pending: _count(operations, 'pending'),
      completed: _count(operations, 'completed'),
      retrying: _count(operations, 'retrying'),
      parked: _count(operations, 'parked'),
      blocked: _count(operations, 'blocked'),
      rejected: _count(operations, 'rejected'),
      households: rows,
    );
  }

  final int pending;
  final int completed;
  final int retrying;
  final int parked;
  final int blocked;
  final int rejected;
  final List<HouseholdSyncStatus> households;

  @override
  List<Object?> get props => [
    pending,
    completed,
    retrying,
    parked,
    blocked,
    rejected,
    households,
  ];

  static int _count(List<SyncOperation> operations, String state) {
    return operations.where((operation) => operation.state == state).length;
  }
}

class HouseholdSyncStatus extends Equatable {
  const HouseholdSyncStatus({
    required this.householdId,
    required this.serverId,
    required this.status,
    required this.operations,
  });

  factory HouseholdSyncStatus.fromOperations({
    required String householdId,
    required String? serverId,
    required List<SyncOperation> operations,
  }) {
    final ordered = [...operations]
      ..sort((left, right) => left.seq.compareTo(right.seq));
    return HouseholdSyncStatus(
      householdId: householdId,
      serverId: serverId,
      status: _status(ordered),
      operations: ordered,
    );
  }

  final String householdId;
  final String? serverId;

  /// Earliest unresolved operation state, or `completed` when every
  /// operation is completed. Null when the household has no operations.
  final String? status;
  final List<SyncOperation> operations;

  @override
  List<Object?> get props => [householdId, serverId, status, operations];

  static String? _status(List<SyncOperation> operations) {
    if (operations.isEmpty) {
      return null;
    }
    for (final operation in operations) {
      if (operation.state != 'completed') {
        return operation.state;
      }
    }
    return 'completed';
  }
}
