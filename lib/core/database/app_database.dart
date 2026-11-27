import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();

  // Tests pass an already-open database, usually in memory.
  AppDatabase.forTesting(Database database) : _database = database;

  //Singleton pattern to ensure only one instance of the database is created
  static final AppDatabase instance = AppDatabase._();

  static const String _databaseName = 'household_survey.db';
  static const int _databaseVersion = 2;

  Database? _database;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    final databasePath = await getDatabasesPath();
    final path = join(databasePath, _databaseName);

    _database = await openDatabase(
      path,
      version: _databaseVersion,
      onConfigure: onConfigure,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
    );

    return _database!;
  }

  static Future<void> onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE households (
        id TEXT PRIMARY KEY,
        server_id TEXT UNIQUE,
        head_name TEXT NOT NULL,
        member_count INTEGER NOT NULL,
        settlement TEXT NOT NULL,
        last_seq INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_operations (
        op_id TEXT PRIMARY KEY,
        household_id TEXT NOT NULL,
        record_id TEXT,
        type TEXT NOT NULL,
        seq INTEGER NOT NULL,
        payload TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        next_retry_at TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (household_id)
          REFERENCES households (id)
          ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_sync_household_seq
      ON sync_operations (household_id, seq)
    ''');

    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  static Future<void> onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2 && newVersion >= 2) {
      await db.execute('ALTER TABLE sync_operations ADD COLUMN record_id TEXT');
    }
  }
}
