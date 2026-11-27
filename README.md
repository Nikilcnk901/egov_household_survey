# Household Survey App

A Flutter application for capturing household details offline and syncing them with a mock API when online.

## Requirements

- Flutter SDK
- Dart SDK
- Docker Desktop
- Android Emulator or iOS Simulator

## 1. Start the Mock API

```bash
cd candidate/mock-api
docker compose up --build
```

API URL: `http://localhost:8080`

## 2. Run the Flutter App

Open another terminal:

```bash
cd egov_household_survey
flutter pub get
flutter run
```

For a custom API address:

```bash
flutter run --dart-define=API_BASE_URL=http://YOUR_API_ADDRESS:8080
```

Use `http://10.0.2.2:8080` for the Android Emulator and `http://127.0.0.1:8080` for the iOS Simulator.

## 3. Run Tests

```bash
flutter test
```

## 4. Switch Chaos Scenarios

Check the active scenario:

```bash
curl http://localhost:8080/admin/chaos
```

Activate a scenario:

```bash
curl -X POST http://localhost:8080/admin/chaos \
  -H "Content-Type: application/json" \
  -d '{"scenario":"lost-ack"}'
```

Available scenarios:

- `none` – Normal API behaviour.
- `lost-ack` – Applies an operation but drops the response.
- `dup-delivery` – Delivers the same request twice.
- `error-burst` – Temporarily returns HTTP 503 errors.
- `slow-network` – Delays API requests.

Replace `lost-ack` with the scenario you want to activate. Use `none` to restore normal behaviour.