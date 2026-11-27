import 'package:egov_household_survey/core/logging/app_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('records level, category, ids, and error details', () {
    final entries = <LogEntry>[];
    final logger = AppLogger(
      clock: () => DateTime.utc(2026, 11, 27, 12, 30),
      write: entries.add,
    );

    logger.info(
      LogCategory.queue,
      'Discovered 1 pending or retrying operations',
      operationId: 'op-1',
      householdId: 'local-1',
      serverId: 'hh-0031',
    );
    logger.error(
      LogCategory.sync,
      'Sync failed',
      operationId: 'op-1',
      error: StateError('connection closed'),
    );

    expect(entries, hasLength(2));
    expect(entries.first.timestamp, DateTime.utc(2026, 11, 27, 12, 30));
    expect(entries.first.level, LogLevel.info);
    expect(entries.first.category, LogCategory.queue);
    expect(entries.first.operationId, 'op-1');
    expect(entries.first.householdId, 'local-1');
    expect(entries.first.serverId, 'hh-0031');
    expect(
      entries.first.line,
      '2026-11-27T12:30:00.000Z INFO QUEUE op=op-1 household=local-1 '
      'server=hh-0031 Discovered 1 pending or retrying operations',
    );
    expect(entries.last.level, LogLevel.error);
    expect(entries.last.category, LogCategory.sync);
    expect(entries.last.line, contains('ERROR SYNC'));
    expect(entries.last.line, contains('error=Bad state: connection closed'));
  });

  test('writes through dart:developer without throwing', () {
    expect(
      () => AppLogger().info(LogCategory.app, 'Household survey ready'),
      returnsNormally,
    );
  });

  test('prints the formatted line and stack trace to the console', () {
    final printed = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      printed.add(message);
    };
    addTearDown(() => debugPrint = original);

    AppLogger(clock: () => DateTime.utc(2026, 11, 27, 12)).error(
      LogCategory.api,
      'API request failed',
      operationId: 'op-1',
      householdId: 'local-1',
      serverId: 'hh-0031',
      error: StateError('down'),
      stackTrace: StackTrace.fromString('stack line'),
    );

    expect(printed, hasLength(2));
    expect(
      printed.first,
      '2026-11-27T12:00:00.000Z ERROR API op=op-1 household=local-1 '
      'server=hh-0031 API request failed error=Bad state: down',
    );
    expect(printed.last, contains('stack line'));
    expect(printed.join('\n'), isNot(contains('head_name')));
  });
}
