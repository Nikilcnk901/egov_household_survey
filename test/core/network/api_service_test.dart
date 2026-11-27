import 'dart:async';
import 'dart:convert';

import 'package:egov_household_survey/core/logging/app_logger.dart';
import 'package:egov_household_survey/core/network/api_service.dart';
import 'package:egov_household_survey/features/sync/domain/sync_operation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('checkHealth returns true when ok is true', () async {
    final service = _service((request) async {
      expect(request.url.path, '/health');
      return http.Response('{"ok": true, "scenario": "none"}', 200);
    });

    expect(await service.checkHealth(), isTrue);
  });

  test('checkHealth throws on a non-success response', () async {
    final service = _service(
      (_) async => http.Response('{"error": "not_found"}', 404),
    );

    await expectLater(
      service.checkHealth(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          404,
        ),
      ),
    );
  });

  test('fetchHouseholds maps server records and checks version', () async {
    final service = _service((request) async {
      expect(request.url.path, '/households');
      return http.Response('''
        {
          "total": 1,
          "items": [
            {
              "id": "hh-0001",
              "head_name": "Amina Wanjiru",
              "member_count": 4,
              "settlement": "Kibera North",
              "version": 1,
              "updated_at": "2026-11-26T12:00:00.000Z"
            }
          ]
        }
        ''', 200);
    });

    final households = await service.fetchHouseholds();

    expect(households, hasLength(1));
    final household = households.single;
    expect(household.id, 'hh-0001');
    expect(household.serverId, 'hh-0001');
    expect(household.headName, 'Amina Wanjiru');
    expect(household.memberCount, 4);
    expect(household.settlement, 'Kibera North');
    expect(household.lastSeq, 0);
    expect(household.createdAt, DateTime.utc(2026, 11, 26, 12));
    expect(household.updatedAt, household.createdAt);
  });

  test('fetchHouseholds uses created_at when the server sends it', () async {
    final service = _service(
      (_) async => http.Response('''
        {
          "total": 1,
          "items": [
            {
              "id": "hh-0002",
              "head_name": "Joseph Otieno",
              "member_count": 3,
              "settlement": "Kibera North",
              "version": 2,
              "created_at": "2026-11-01T08:00:00.000Z",
              "updated_at": "2026-11-26T12:00:00.000Z"
            }
          ]
        }
        ''', 200),
    );

    final household = (await service.fetchHouseholds()).single;

    expect(household.createdAt, DateTime.utc(2026, 11, 1, 8));
    expect(household.updatedAt, DateTime.utc(2026, 11, 26, 12));
  });

  test('fetchHouseholds throws when version is missing', () async {
    final service = _service(
      (_) async => http.Response('''
        {
          "total": 1,
          "items": [
            {
              "id": "hh-0001",
              "head_name": "Amina Wanjiru",
              "member_count": 4,
              "settlement": "Kibera North",
              "updated_at": "2026-11-26T12:00:00.000Z"
            }
          ]
        }
        ''', 200),
    );

    await expectLater(service.fetchHouseholds(), throwsA(isA<ApiException>()));
  });

  test('fetchHouseholds throws on malformed JSON', () async {
    final service = _service((_) async => http.Response('{', 200));

    await expectLater(service.fetchHouseholds(), throwsA(isA<ApiException>()));
  });

  test(
    'syncOperation maps an applied create and omits a null record id',
    () async {
      final service = _service((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/sync');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final operation = (body['operations'] as List).single as Map;
        expect(operation['op_id'], 'stable-operation-id');
        expect(operation['type'], 'create');
        expect(operation['seq'], 1);
        expect(operation.containsKey('record_id'), isFalse);
        expect(operation['payload'], {
          'head_name': 'Test',
          'member_count': 3,
          'settlement': 'Settlement A',
        });
        return http.Response('''
        {
          "results": [
            {
              "op_id": "stable-operation-id",
              "status": "applied",
              "household": {"id": "hh-0031"}
            }
          ]
        }
        ''', 200);
      });

      final result = await service.syncOperation(_operation());

      expect(result.opId, 'stable-operation-id');
      expect(result.status, SyncResultStatus.applied);
      expect(result.serverHouseholdId, 'hh-0031');
      expect(result.error, isNull);
    },
  );

  test('syncOperation maps a duplicate response with a server id', () async {
    final service = _service(
      (_) async => http.Response('''
        {
          "results": [
            {
              "op_id": "stable-operation-id",
              "status": "duplicate",
              "household": {"id": "hh-0031"}
            }
          ]
        }
        ''', 200),
    );

    final result = await service.syncOperation(_operation());

    expect(result.status, SyncResultStatus.duplicate);
    expect(result.serverHouseholdId, 'hh-0031');
    expect(result.error, isNull);
  });

  test('syncOperation maps a stale response', () async {
    final service = _service(
      (_) async => http.Response('''
        {
          "results": [
            {
              "op_id": "stable-operation-id",
              "status": "stale",
              "error": "an operation with a higher seq was already applied"
            }
          ]
        }
        ''', 200),
    );

    final result = await service.syncOperation(
      _operation(type: 'update', recordId: 'hh-0001'),
    );

    expect(result.status, SyncResultStatus.stale);
    expect(result.serverHouseholdId, isNull);
    expect(result.error, 'an operation with a higher seq was already applied');
  });

  test('syncOperation maps a rejected response and sends record id', () async {
    final service = _service((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final operation = (body['operations'] as List).single as Map;
      expect(operation['type'], 'update');
      expect(operation['record_id'], 'hh-0001');
      return http.Response('''
        {
          "results": [
            {
              "op_id": "stable-operation-id",
              "status": "rejected",
              "error": "household hh-0001 not found"
            }
          ]
        }
        ''', 200);
    });

    final result = await service.syncOperation(
      _operation(type: 'update', recordId: 'hh-0001'),
    );

    expect(result.status, SyncResultStatus.rejected);
    expect(result.serverHouseholdId, isNull);
    expect(result.error, 'household hh-0001 not found');
  });

  test('syncOperation preserves HTTP 503 and Retry-After', () async {
    final service = _service(
      (_) async => http.Response(
        '{"error":"service_unavailable"}',
        503,
        headers: const {'retry-after': '5'},
      ),
    );

    await expectLater(
      service.syncOperation(_operation()),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 503)
            .having(
              (error) => error.retryAfter,
              'retryAfter',
              const Duration(seconds: 5),
            ),
      ),
    );
  });

  test('syncOperation throws on a malformed response', () async {
    final service = _service((_) async => http.Response('{', 200));

    await expectLater(
      service.syncOperation(_operation()),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', isNull)
            .having(
              (error) => error,
              'not a transport failure',
              isNot(isA<TransportException>()),
            ),
      ),
    );
  });

  test('syncOperation logs the request body and response', () async {
    final logs = <LogEntry>[];
    final service = ApiService(
      baseUrl: 'http://localhost:8080',
      client: MockClient(
        (_) async => http.Response('''
          {
            "results": [
              {
                "op_id": "stable-operation-id",
                "status": "applied",
                "household": {"id": "hh-0031"}
              }
            ]
          }
          ''', 200),
      ),
      logger: AppLogger(
        clock: () => DateTime.utc(2026, 11, 27, 12),
        write: logs.add,
      ),
    );

    await service.syncOperation(_operation());

    expect(logs.map((entry) => entry.message), [
      'POST /sync started',
      '[REQUEST]\n'
          'type=create\n'
          'seq=1\n'
          'body={"operations":[{"op_id":"stable-operation-id","type":"create","seq":1,"payload":{"head_name":"Test","member_count":3,"settlement":"Settlement A"}}]}',
      'POST /sync response applied',
      '[RESPONSE]\n'
          'http=200\n'
          'status=applied\n'
          'server=hh-0031\n'
          'error=none',
    ]);
    expect(logs.every((entry) => entry.category == LogCategory.api), isTrue);
    expect(logs.first.operationId, 'stable-operation-id');
    expect(logs.first.householdId, 'local-1');
    expect(logs.last.serverId, 'hh-0031');
    expect(logs.map((entry) => entry.line).join('\n'), contains('head_name'));
    expect(
      logs.map((entry) => entry.line).join('\n'),
      isNot(contains('Authorization')),
    );
    expect(
      logs.map((entry) => entry.line).join('\n'),
      isNot(contains('password')),
    );
  });

  test('syncOperation logs an HTTP failure response', () async {
    final logs = <LogEntry>[];
    final service = ApiService(
      baseUrl: 'http://localhost:8080',
      client: MockClient(
        (_) async => http.Response(
          '{"error":"service_unavailable"}',
          503,
          headers: const {'retry-after': '5'},
        ),
      ),
      logger: AppLogger(
        clock: () => DateTime.utc(2026, 11, 27, 12),
        write: logs.add,
      ),
    );

    await expectLater(
      service.syncOperation(_operation()),
      throwsA(isA<ApiException>()),
    );

    final response = logs.singleWhere(
      (entry) => entry.message.startsWith('[RESPONSE]'),
    );
    expect(response.level, LogLevel.error);
    expect(response.operationId, 'stable-operation-id');
    expect(response.householdId, 'local-1');
    expect(response.message, contains('http=503'));
    expect(response.message, contains('status=none'));
    expect(logs.map((entry) => entry.message), contains('POST /sync failed'));
  });

  test(
    'syncOperation reports a network failure as a transport failure',
    () async {
      final service = _service((_) async {
        throw http.ClientException('connection closed');
      });

      await expectLater(
        service.syncOperation(_operation()),
        throwsA(
          isA<TransportException>()
              .having((error) => error.message, 'message', 'connection closed')
              .having(
                (error) => error.cause,
                'cause',
                isA<http.ClientException>(),
              )
              .having(
                (error) => error,
                'not an API response failure',
                isNot(isA<ApiException>()),
              ),
        ),
      );
    },
  );

  test('syncOperation reports a timeout as a transport failure', () async {
    final service = _service((_) async {
      throw TimeoutException('timed out');
    });

    await expectLater(
      service.syncOperation(_operation()),
      throwsA(
        isA<TransportException>().having(
          (error) => error.message,
          'message',
          'POST /sync timed out after 20 seconds',
        ),
      ),
    );
  });
}

SyncOperation _operation({String type = 'create', String? recordId}) {
  return SyncOperation(
    opId: 'stable-operation-id',
    householdId: 'local-1',
    recordId: recordId,
    type: type,
    seq: 1,
    payload: const {
      'head_name': 'Test',
      'member_count': 3,
      'settlement': 'Settlement A',
    },
    createdAt: DateTime.utc(2026, 11, 27),
  );
}

ApiService _service(MockClientHandler handler) {
  return ApiService(
    baseUrl: 'http://localhost:8080',
    client: MockClient(handler),
  );
}
