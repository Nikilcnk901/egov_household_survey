# Implementation Plan – Household Survey App

## 1. Work Plan

### Day 1 – 26 November 2026

- **Start time:** 11:00 PM IST
- **Stop time:** 12:00 AM IST

**Completed:**
- Set up the SQLite database and household data models.
- Implemented household and sync repositories.
- Added atomic household and sync operation insertion.
- Added in-memory SQLite repository tests.
- Verified transaction rollback and per-household operation ordering.

### Day 2 – 27 November 2026

#### Session 1 – Household Management

- **Start time:** 10:42 AM IST
- **Stop time:** 11:42 AM IST
- **Duration:** 60 minutes

**Completed:**
- Added database version 2 migration to support the nullable `record_id` field.
- Updated the `SyncOperation` model to store and retrieve the backend record ID.
- Implemented `HouseholdCubit` and its UI states.
- Implemented local household creation using a temporary UUID and a unique operation UUID.
- Implemented atomic household updates with corresponding sync operations.
- Added sequence number management for household updates.
- Implemented the household list screen.
- Created household creation and editing forms.
- Added form validation for household name, settlement, and member count.
- Connected the UI to `HouseholdCubit`.
- Tested household creation, editing, and persistence using the iOS simulator.

#### Session 2 – API Integration and Online/Offline Handling

- **Start time:** 11:45 AM IST
- **Stop time:** 12:15 PM IST
- **Duration:** 30 minutes

**Completed:**

**API Integration**
- Implemented `ApiService` using the HTTP package.
- Added backend health check using `GET /health`.
- Implemented household fetching using `GET /households`.
- Added JSON parsing and API exception handling.
- Added request timeout handling.
- Integrated `ApiService` with `HouseholdRepository`.
- Implemented initial server household loading into SQLite.
- Prevented duplicate server record insertion.
- Preserved existing local household records and pending sync operations.
- Added transactional insertion for initial server data.

**Online/Offline Handling**
- Implemented `SettingsRepository` using the existing `app_settings` table.
- Added persistent online/offline mode.
- Set online as the default mode when no preference exists.
- Added an online/offline switch to the household list screen.
- Prevented backend API calls when offline mode is selected.
- Implemented initial server loading when switching online.
- Prevented repeated or concurrent initial fetches.

#### Session 3 – Retry, Dismissal and Queue Handling

- **Start time:** 2:30 PM IST
- **Stop time:** 3:15 PM IST
- **Duration:** 45 minutes

**Completed:**
- Implemented Retry and Dismiss actions for sync operations.
- Added separate handling for parked and rejected operations.
- Added logic to block later operations when an earlier operation needs attention.
- Added tests for retry, dismissal, and operation blocking.

#### Session 4 – Manual Testing and Issue Investigation

- **Start time:** 3:20 PM IST
- **Stop time:** 4:00 PM IST
- **Duration:** 45 minutes

**Completed:**
- Manually tested the Retry flow.
- Identified an issue with a duplicate CREATE response that did not contain a server ID.
- Prepared a focused fix for duplicate-response handling.
- Reviewed the retry and parked-state testing process.
- Started consolidating implementation and testing details for project documentation.

### Time Summary

| Work session | Duration |
|---|---:|
| Day 1 – Session 1 | 60 minutes |
| Day 2 – Session 1 | 60 minutes |
| Day 2 – Session 2 | 30 minutes |
| Day 2 – Session 3 | 45 minutes |
| Day 2 – Session 4 | 45 minutes |
| **Total** | **240 minutes (4 hours)** |

The recorded work sessions total 3 hours and 55 minutes, within the four-hour assignment limit.

## 2. Architecture

The application uses a simple layered structure to separate the UI, local storage, and synchronization logic.

- **Flutter:** Application UI.
- **Cubit:** Manages household and sync queue screen states.
- **SQLite (`sqflite`):** Stores households, pending operations, and application settings.
- **HTTP:** Communicates with the mock API.
- **UUID:** Generates temporary household IDs and unique operation IDs.

The household screens read and update local data. A separate sync engine processes queued operations and sends them to the server when the application is online.

## 3. Data Model

The application uses two main database tables and a settings table.

**Households**
- `id`
- `server_id`
- `head_name`
- `member_count`
- `settlement`
- `last_seq`
- `created_at`
- `updated_at`

**Sync Operations**
- `op_id`
- `household_id`
- `record_id`
- `type`
- `seq`
- `payload`
- `state`
- `attempt_count`
- `next_retry_at`
- `last_error`
- `created_at`

**Settings**

The `app_settings` table stores the online/offline preference so that it is retained after restarting the application.

Household changes and their corresponding sync operations are saved within a single database transaction to prevent partial updates.

## 4. API Integration

The application integrates with the following endpoints:

- `GET /health` – Check backend availability.
- `GET /households` – Load the initial household list.
- `POST /sync` – Send CREATE and UPDATE operations.

Each sync operation includes `op_id`, `type`, `seq`, and `payload`. The `record_id` is included for operations that reference an existing server record. CREATE operations omit it until the server assigns an ID.

The admin endpoints are used separately to switch chaos scenarios during testing.

## 5. Testing

Testing focuses on:

- Creating and editing households, including form validation.
- Saving and retrieving data while offline.
- Atomic database transactions and rollback.
- Per-household operation ordering.
- Duplicate operation handling and idempotency.
- Retry delays and parked operations.
- Blocking dependent operations when an earlier operation needs attention.
- Restoring household and queue states after an app restart.
- Household list and sync queue UI behaviour.

The application was also tested against the supplied mock API using the `dup-delivery` and `error-burst` scenarios, along with manual testing of offline behaviour and operation ordering.

The `lost-ack` scenario was reviewed, but a successful manual lost-ack recovery test was not completed within the available time.

## 6. If I Had One More Day

I would use the additional time to:

- Complete manual testing of the lost-ack recovery scenario.
- Add more integration tests for sync and restart scenarios.
- Improve error handling and edge-case coverage.
- Test database recovery and server restart behaviour.
- Refine the sync queue UI and improve the overall user experience.
