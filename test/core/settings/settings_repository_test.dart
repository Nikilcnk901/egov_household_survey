import 'package:egov_household_survey/core/database/app_database.dart';
import 'package:egov_household_survey/core/settings/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database database;
  late SettingsRepository settings;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: AppDatabase.onConfigure,
        onCreate: AppDatabase.onCreate,
      ),
    );
    settings = SettingsRepository(
      appDatabase: AppDatabase.forTesting(database),
    );
  });

  tearDown(() async {
    await database.close();
  });

  test('defaults to online when no setting exists', () async {
    expect(await settings.isOnline(), isTrue);
    expect(await database.query('app_settings'), isEmpty);
  });

  test('persists the selected mode for a new repository', () async {
    final appDatabase = AppDatabase.forTesting(database);

    await settings.setOnline(false);
    expect(
      await SettingsRepository(appDatabase: appDatabase).isOnline(),
      isFalse,
    );

    await settings.setOnline(true);
    expect(
      await SettingsRepository(appDatabase: appDatabase).isOnline(),
      isTrue,
    );
  });
}
