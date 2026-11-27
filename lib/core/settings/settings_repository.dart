import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';

class SettingsRepository {
  SettingsRepository({AppDatabase? appDatabase})
    : _appDatabase = appDatabase ?? AppDatabase.instance;

  static const String onlineKey = 'online';

  final AppDatabase _appDatabase;

  Future<bool> isOnline() async {
    final db = await _appDatabase.database;
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [onlineKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return true;
    }
    return rows.first['value'] == 'true';
  }

  Future<void> setOnline(bool online) async {
    final db = await _appDatabase.database;
    await db.insert('app_settings', {
      'key': onlineKey,
      'value': online ? 'true' : 'false',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
