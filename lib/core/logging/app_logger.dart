import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

enum LogLevel {
  info('INFO', 800),
  warning('WARNING', 900),
  error('ERROR', 1000);

  const LogLevel(this.label, this.value);

  final String label;
  final int value;
}

enum LogCategory {
  app('APP'),
  database('DATABASE'),
  household('HOUSEHOLD'),
  queue('QUEUE'),
  sync('SYNC'),
  api('API');

  const LogCategory(this.label);

  final String label;
}

class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
    this.operationId,
    this.householdId,
    this.serverId,
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;
  final LogLevel level;
  final LogCategory category;
  final String message;
  final String? operationId;
  final String? householdId;
  final String? serverId;
  final Object? error;
  final StackTrace? stackTrace;

  String get line {
    final parts = <String>[
      timestamp.toUtc().toIso8601String(),
      level.label,
      category.label,
      if (operationId != null) 'op=$operationId',
      if (householdId != null) 'household=$householdId',
      if (serverId != null) 'server=$serverId',
      message,
      if (error != null) 'error=$error',
    ];
    return parts.join(' ');
  }
}

class AppLogger {
  AppLogger({DateTime Function()? clock, void Function(LogEntry entry)? write})
    : _clock = clock ?? DateTime.now,
      _write = write ?? _writeToDeveloper;

  final DateTime Function() _clock;
  final void Function(LogEntry entry) _write;

  void info(
    LogCategory category,
    String message, {
    String? operationId,
    String? householdId,
    String? serverId,
  }) {
    _log(
      LogLevel.info,
      category,
      message,
      operationId: operationId,
      householdId: householdId,
      serverId: serverId,
    );
  }

  void warning(
    LogCategory category,
    String message, {
    String? operationId,
    String? householdId,
    String? serverId,
  }) {
    _log(
      LogLevel.warning,
      category,
      message,
      operationId: operationId,
      householdId: householdId,
      serverId: serverId,
    );
  }

  void error(
    LogCategory category,
    String message, {
    String? operationId,
    String? householdId,
    String? serverId,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _log(
      LogLevel.error,
      category,
      message,
      operationId: operationId,
      householdId: householdId,
      serverId: serverId,
      error: error,
      stackTrace: stackTrace,
    );
  }

  void _log(
    LogLevel level,
    LogCategory category,
    String message, {
    String? operationId,
    String? householdId,
    String? serverId,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final entry = LogEntry(
      timestamp: _clock().toUtc(),
      level: level,
      category: category,
      message: message,
      operationId: operationId,
      householdId: householdId,
      serverId: serverId,
      error: error,
      stackTrace: stackTrace,
    );
    _write(entry);
  }

  static void _writeToDeveloper(LogEntry entry) {
    developer.log(
      entry.line,
      time: entry.timestamp,
      level: entry.level.value,
      name: entry.category.label,
      error: entry.error,
      stackTrace: entry.stackTrace,
    );
    debugPrint(entry.line);
    final stackTrace = entry.stackTrace;
    if (stackTrace != null) {
      debugPrint(stackTrace.toString());
    }
  }
}
