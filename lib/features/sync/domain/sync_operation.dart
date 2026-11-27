import 'dart:convert';

class SyncOperation {
  final String opId;
  final String householdId;
  final String? recordId;
  final String type;
  final int seq;
  final Map<String, dynamic> payload;
  final String state;
  final int attemptCount;
  final DateTime? nextRetryAt;
  final String? lastError;
  final DateTime createdAt;

  const SyncOperation({
    required this.opId,
    required this.householdId,
    this.recordId,
    required this.type,
    required this.seq,
    required this.payload,
    this.state = 'pending',
    this.attemptCount = 0,
    this.nextRetryAt,
    this.lastError,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'op_id': opId,
      'household_id': householdId,
      'record_id': recordId,
      'type': type,
      'seq': seq,
      'payload': jsonEncode(payload),
      'state': state,
      'attempt_count': attemptCount,
      'next_retry_at': nextRetryAt?.toIso8601String(),
      'last_error': lastError,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory SyncOperation.fromMap(Map<String, dynamic> map) {
    return SyncOperation(
      opId: map['op_id'] as String,
      householdId: map['household_id'] as String,
      recordId: map['record_id'] as String?,
      type: map['type'] as String,
      seq: map['seq'] as int,
      payload: Map<String, dynamic>.from(
        jsonDecode(map['payload'] as String) as Map,
      ),
      state: map['state'] as String,
      attemptCount: map['attempt_count'] as int,
      nextRetryAt: map['next_retry_at'] != null
          ? DateTime.parse(map['next_retry_at'] as String)
          : null,
      lastError: map['last_error'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
