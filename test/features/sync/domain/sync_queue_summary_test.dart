import 'package:egov_household_survey/features/households/domain/household.dart';
import 'package:egov_household_survey/features/sync/domain/sync_operation.dart';
import 'package:egov_household_survey/features/sync/domain/sync_queue_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('counts queue states and uses the earliest unresolved operation', () {
    final summary = SyncQueueSummary.from(
      [
        _household('local-1', serverId: 'hh-0031'),
        _household('local-2'),
        _household('local-empty', serverId: 'hh-0004'),
      ],
      [
        _operation(
          opId: 'later',
          householdId: 'local-1',
          seq: 2,
          state: 'pending',
          attemptCount: 1,
        ),
        _operation(
          opId: 'parked',
          householdId: 'local-1',
          seq: 1,
          state: 'parked',
          attemptCount: 5,
          lastError: 'household not found',
        ),
        _operation(opId: 'done', householdId: 'local-2', state: 'completed'),
        _operation(
          opId: 'again',
          householdId: 'local-3',
          state: 'retrying',
          recordId: 'hh-0009',
          attemptCount: 2,
          lastError: 'timed out',
        ),
        _operation(
          opId: 'waiting',
          householdId: 'local-3',
          seq: 2,
          state: 'blocked',
        ),
      ],
    );

    expect(summary.pending, 1);
    expect(summary.completed, 1);
    expect(summary.retrying, 1);
    expect(summary.parked, 1);
    expect(summary.blocked, 1);
    expect(summary.rejected, 0);

    final parked = summary.households[0];
    expect(parked.householdId, 'local-1');
    expect(parked.serverId, 'hh-0031');
    expect(parked.status, 'parked');
    expect(parked.operations.map((operation) => operation.seq), [1, 2]);
    expect(parked.operations.first.attemptCount, 5);
    expect(parked.operations.first.lastError, 'household not found');
    expect(parked.operations.first.type, 'create');

    expect(summary.households[1].status, 'completed');
    expect(summary.households[1].serverId, isNull);
    expect(summary.households[2].householdId, 'local-empty');
    expect(summary.households[2].status, isNull);
    expect(summary.households[2].operations, isEmpty);

    final retrying = summary.households[3];
    expect(retrying.householdId, 'local-3');
    expect(retrying.serverId, 'hh-0009');
    expect(retrying.status, 'retrying');
    expect(retrying.operations.last.state, 'blocked');
  });

  test('counts a rejected operation as the household status', () {
    final summary = SyncQueueSummary.from(
      [_household('local-1', serverId: 'hh-0004')],
      [
        _operation(
          opId: 'rejected',
          householdId: 'local-1',
          type: 'update',
          state: 'rejected',
          lastError: 'head name is empty',
        ),
        _operation(
          opId: 'later',
          householdId: 'local-1',
          type: 'update',
          seq: 2,
          state: 'blocked',
        ),
      ],
    );

    expect(summary.rejected, 1);
    expect(summary.blocked, 1);
    expect(summary.parked, 0);
    expect(summary.households.single.status, 'rejected');
    expect(
      summary.households.single.operations.first.lastError,
      'head name is empty',
    );
  });
}

Household _household(String id, {String? serverId}) {
  final createdAt = DateTime.utc(2026, 11, 26, 9);
  return Household(
    id: id,
    serverId: serverId,
    headName: 'Asha Noor',
    memberCount: 4,
    settlement: 'Kibera North',
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

SyncOperation _operation({
  required String opId,
  required String householdId,
  String type = 'create',
  int seq = 1,
  String state = 'pending',
  String? recordId,
  int attemptCount = 0,
  String? lastError,
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
    lastError: lastError,
    createdAt: DateTime.utc(2026, 11, 27, 10),
  );
}
