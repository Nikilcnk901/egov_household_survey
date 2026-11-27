import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../features/households/domain/household.dart';
import '../../features/sync/domain/sync_operation.dart';
import '../logging/app_logger.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode, this.retryAfter});

  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  @override
  String toString() {
    final buffer = StringBuffer('ApiException');
    if (statusCode != null) {
      buffer.write(' ($statusCode)');
    }
    buffer.write(': $message');
    if (retryAfter != null) {
      buffer.write(' (retry after ${retryAfter!.inSeconds}s)');
    }
    return buffer.toString();
  }
}

/// A network failure or timeout while sending a request.
///
/// Malformed JSON and invalid response bodies stay [ApiException]s.
class TransportException implements Exception {
  TransportException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) {
      return 'TransportException: $message';
    }
    return 'TransportException: $message ($cause)';
  }
}

enum SyncResultStatus { applied, duplicate, stale, rejected }

class SyncResult {
  const SyncResult({
    required this.opId,
    required this.status,
    this.serverHouseholdId,
    this.error,
  });

  final String opId;
  final SyncResultStatus status;
  final String? serverHouseholdId;
  final String? error;
}

class ApiService {
  ApiService({
    required String baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    AppLogger? logger,
  }) : _baseUrl = _withoutTrailingSlash(baseUrl),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _logger = logger ?? AppLogger();

  final String _baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;
  final AppLogger _logger;

  /// Closes the client this service created. An injected client is left open.
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<bool> checkHealth() async {
    final body = await _getObject('/health');
    final ok = body['ok'];
    if (ok is! bool) {
      throw ApiException('Health response is missing boolean ok');
    }
    return ok;
  }

  Future<List<Household>> fetchHouseholds() async {
    final body = await _getObject('/households');
    final total = body['total'];
    final items = body['items'];
    if (total is! int) {
      throw ApiException('Household list is missing integer total');
    }
    if (items is! List) {
      throw ApiException('Household list is missing items');
    }
    if (total != items.length) {
      throw ApiException(
        'Household list total $total does not match ${items.length} items',
      );
    }

    return items.map(_householdFromJson).toList();
  }

  Future<SyncResult> syncOperation(SyncOperation operation) async {
    final request = {
      'operations': [_operationBody(operation)],
    };
    _logger.info(
      LogCategory.api,
      'POST /sync started',
      operationId: operation.opId,
      householdId: operation.householdId,
      serverId: operation.recordId,
    );
    _logger.info(
      LogCategory.api,
      '[REQUEST]\n'
      'type=${operation.type}\n'
      'seq=${operation.seq}\n'
      'body=${jsonEncode(request)}',
      operationId: operation.opId,
      householdId: operation.householdId,
      serverId: operation.recordId,
    );
    try {
      final response = await _post('/sync', request);
      final decoded = _decodeJson(response.body, '/sync', method: 'POST');
      if (decoded is! Map) {
        throw ApiException('POST /sync returned JSON that is not an object');
      }
      final result = _syncResultFromJson(
        Map<String, dynamic>.from(decoded),
        operation,
      );
      final detail = result.error == null
          ? result.status.name
          : '${result.status.name}: ${result.error}';
      _logger.info(
        LogCategory.api,
        'POST /sync response $detail',
        operationId: operation.opId,
        householdId: operation.householdId,
        serverId: result.serverHouseholdId ?? operation.recordId,
      );
      _logger.info(
        LogCategory.api,
        '[RESPONSE]\n'
        'http=${response.statusCode}\n'
        'status=${result.status.name}\n'
        'server=${result.serverHouseholdId ?? 'none'}\n'
        'error=${result.error ?? 'none'}',
        operationId: operation.opId,
        householdId: operation.householdId,
        serverId: result.serverHouseholdId ?? operation.recordId,
      );
      return result;
    } catch (error, stackTrace) {
      final statusCode = error is ApiException ? error.statusCode : null;
      _logger.error(
        LogCategory.api,
        'POST /sync failed',
        operationId: operation.opId,
        householdId: operation.householdId,
        serverId: operation.recordId,
        error: error,
        stackTrace: stackTrace,
      );
      _logger.error(
        LogCategory.api,
        '[RESPONSE]\n'
        'http=${statusCode ?? 'none'}\n'
        'status=none\n'
        'error=$error',
        operationId: operation.opId,
        householdId: operation.householdId,
        serverId: operation.recordId,
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Map<String, dynamic> _operationBody(SyncOperation operation) {
    final body = <String, dynamic>{
      'op_id': operation.opId,
      'type': operation.type,
      'seq': operation.seq,
      'payload': operation.payload,
    };
    if (operation.type == 'update' || operation.recordId != null) {
      body['record_id'] = operation.recordId;
    }
    return body;
  }

  SyncResult _syncResultFromJson(
    Map<String, dynamic> body,
    SyncOperation operation,
  ) {
    final results = body['results'];
    if (results is! List || results.length != 1) {
      throw ApiException('POST /sync returned an unexpected results array');
    }
    final item = results.single;
    if (item is! Map) {
      throw ApiException('POST /sync result is not an object');
    }
    final json = Map<String, dynamic>.from(item);
    final opId = json['op_id'];
    if (opId is! String || opId.isEmpty || opId != operation.opId) {
      throw ApiException('POST /sync result has an unexpected op_id');
    }

    final status = _syncStatus(json['status']);
    if (status == null) {
      throw ApiException('POST /sync result has an unexpected status');
    }

    return SyncResult(
      opId: opId,
      status: status,
      serverHouseholdId: _serverHouseholdId(json['household']),
      error: _optionalError(json['error']),
    );
  }

  SyncResultStatus? _syncStatus(Object? value) {
    return switch (value) {
      'applied' => SyncResultStatus.applied,
      'duplicate' => SyncResultStatus.duplicate,
      'stale' => SyncResultStatus.stale,
      'rejected' => SyncResultStatus.rejected,
      _ => null,
    };
  }

  String? _serverHouseholdId(Object? household) {
    if (household == null) {
      return null;
    }
    if (household is! Map) {
      throw ApiException('POST /sync household is not an object');
    }
    final id = household['id'];
    if (id is! String || id.trim().isEmpty) {
      throw ApiException('POST /sync household is missing id');
    }
    return id;
  }

  String? _optionalError(Object? error) {
    if (error == null) {
      return null;
    }
    if (error is! String) {
      throw ApiException('POST /sync error is not a string');
    }
    return error;
  }

  Future<Map<String, dynamic>> _getObject(String path) async {
    final response = await _get(path);
    final decoded = _decodeJson(response.body, path);
    if (decoded is! Map) {
      throw ApiException('GET $path returned JSON that is not an object');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<http.Response> _get(String path) async {
    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse('$_baseUrl$path'))
          .timeout(timeout);
    } on TimeoutException {
      throw ApiException(
        'GET $path timed out after ${timeout.inSeconds} seconds',
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'GET $path failed',
        statusCode: response.statusCode,
        retryAfter: _retryAfter(response),
      );
    }
    return response;
  }

  Future<http.Response> _post(String path, Object? body) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_baseUrl$path'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw TransportException(
        'POST $path timed out after ${timeout.inSeconds} seconds',
      );
    } on http.ClientException catch (error) {
      throw TransportException(
        error.message.isEmpty ? error.toString() : error.message,
        cause: error,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        'POST $path failed',
        statusCode: response.statusCode,
        retryAfter: _retryAfter(response),
      );
    }
    return response;
  }

  Duration? _retryAfter(http.Response response) {
    final header = response.headers['retry-after']?.trim();
    if (header == null || header.isEmpty) {
      return null;
    }
    final seconds = int.tryParse(header);
    if (seconds == null || seconds < 0) {
      return null;
    }
    return Duration(seconds: seconds);
  }

  Object? _decodeJson(String body, String path, {String method = 'GET'}) {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw ApiException('$method $path returned malformed JSON');
    }
  }

  Household _householdFromJson(Object? item) {
    if (item is! Map) {
      throw ApiException('Household item is not an object');
    }
    final json = Map<String, dynamic>.from(item);
    final id = _requireText(json, 'id');

    // `version` is required on the wire. Household has no version field, and
    // the local schema is unchanged, so the value is checked and not stored.
    // It is not copied into lastSeq. Server rows start at lastSeq 0.
    if (json['version'] is! int) {
      throw ApiException('Household $id is missing integer version');
    }

    final updatedAt = _requireDate(json, 'updated_at');
    final createdRaw = json['created_at'];
    final createdAt = createdRaw == null
        ? updatedAt
        : _requireDate(json, 'created_at');

    return Household(
      id: id,
      serverId: id,
      headName: _requireText(json, 'head_name'),
      memberCount: _requireInt(json, 'member_count'),
      settlement: _requireText(json, 'settlement'),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  String _requireText(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value is! String || value.trim().isEmpty) {
      throw ApiException('Household is missing $field');
    }
    return value;
  }

  int _requireInt(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value is! int) {
      throw ApiException('Household is missing integer $field');
    }
    return value;
  }

  DateTime _requireDate(Map<String, dynamic> json, String field) {
    final value = json[field];
    if (value is! String || value.isEmpty) {
      throw ApiException('Household is missing $field');
    }
    try {
      return DateTime.parse(value);
    } on FormatException {
      throw ApiException('Household field $field is not a valid date');
    }
  }

  static String _withoutTrailingSlash(String baseUrl) {
    if (baseUrl.endsWith('/')) {
      return baseUrl.substring(0, baseUrl.length - 1);
    }
    return baseUrl;
  }
}
