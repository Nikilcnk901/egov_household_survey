# Offline-First Household Survey Capture

## 1. Problem Restatement

Field workers need to register and update households using phones that may be offline for hours. Changes should be saved on the device immediately and synced with the server when the connection is available.

The supplied mock API stores household records, starts with 30 seeded records, and supports create and update operations through `POST /sync`. It also provides scenarios for lost acknowledgements, duplicate requests, temporary server failures, and slow network responses.

The app needs to:

- Display households from local storage, including their ID, head name, member count, and settlement.
- Allow users to create and edit households with basic validation.
- Save changes locally before attempting to sync them.
- Maintain a sync queue showing pending, retrying, parked, blocked, rejected, and completed operations.
- Provide an Online/Offline switch. The app must not make HTTP requests while offline.
- Send operations for each household in the correct order.
- Preserve household data and queue state after an app restart.
- Handle retries and duplicate responses without creating duplicate records or applying the same update twice.

## 2. Ambiguities and Decisions

### Local Storage and State Management

I chose SQLite using `sqflite` because both household records and pending operations need to be stored locally. Saving a household and adding its operation to the queue are done in a single database transaction.

I used Cubit for the household list and sync queue state management. The sync logic is handled separately so that it does not depend on the UI.

The Online/Offline switch controls syncing. A connectivity plugin is not required because the assignment specifically asks for a manual switch.

### Household ID Generation

The server generates a household ID when a CREATE operation does not include `record_id`.

I generate a temporary UUID on the device when a household is created. This ID is used to identify the household locally before the first sync completes.

After the server successfully creates the household, the application stores the server-generated ID against the local household. Any queued operations that depend on the server ID are updated to reference it.

This allows the application to maintain a stable local reference while supporting server-generated IDs.

### Operation IDs and Duplicate Requests

Each queued operation has a unique UUID stored as `op_id`. The same ID and payload are retained when an operation is retried.

The mock API remembers previously processed operation IDs and returns `duplicate` when it receives the same operation again.

A successful duplicate response is treated as completed, just like `applied` and `stale` responses. A duplicate CREATE response without a server ID and containing an error requires special handling so that an invalid operation is not incorrectly marked as synced.

### Operation Ordering

The server supports a `seq` value for each household. An update with a sequence number less than or equal to the last applied sequence is rejected as stale.

The application maintains an increasing sequence number for each household and processes its operations in order. A later operation waits until the earlier operation is resolved.

Each household can sync independently. If one household has an operation waiting for a retry or requiring attention, it should not prevent other households from being processed.

One operation is sent per API request to keep queue handling and error handling straightforward.

### Retry Policy

The assignment does not specify the retry limit or delay, so I implemented an exponential backoff retry policy.

- Initial retry delay: 2 seconds.
- Backoff multiplier: 2.
- Maximum retry delay: 60 seconds.
- Jitter: ±20%.
- Maximum retry attempts: 5.
- `Retry-After` is respected when supplied by the server.

Transport errors, timeouts, HTTP 408, HTTP 429, and server errors are treated as retryable. Permanent client errors are parked rather than retried indefinitely.

The request timeout is configured to accommodate the supplied slow-network scenario, which can delay responses by up to 9 seconds.

### Parked and Blocked Operations

When an operation is parked, later operations for the same household are marked as blocked. They are not sent until the earlier operation is resolved.

The user can retry a parked operation using the same `op_id` and payload. The retry state is reset to allow another set of attempts.

A permanently rejected operation remains visible until the user dismisses it.

Dismissing a rejected update removes that failed operation and allows eligible later operations to continue. Dismissing a rejected CREATE also removes its dependent operations and the unsynced local household when it has no server ID.

### Lost Acknowledgements

The mock API can apply an operation and then drop the response. In this situation, the client cannot know whether the server processed the request.

The intended recovery mechanism is to retain the operation and retry it using the same `op_id`. If the server has already applied it, the duplicate response should allow the client to complete the operation without applying it again.

The payload must remain unchanged between attempts. The operation ID therefore remains stable throughout its retry lifecycle.

The mock API keeps processed operation IDs in memory, so this protection does not survive a server restart. Handling server-side data loss is outside this implementation.

### Persistence and App Restart

Household records, queued operations, sequence numbers, retry counts, retry deadlines, operation states, and the Online/Offline setting are stored in SQLite.

When the app restarts, it restores the previous household and queue state. Parked and blocked operations remain visible, and eligible operations can resume syncing when the app is running and Online mode is enabled.

Background syncing while the app is suspended is not part of this implementation.

### Initial Household Data

The app loads the seeded households from `GET /households` when online.

Downloaded records are stored locally without creating sync queue operations. Existing local household records and pending operations are preserved, and duplicate server records are not inserted again.

The initial fetch is also triggered when switching from Offline to Online mode.

## 3. Out of Scope

- Deleting synced households, since the supplied API does not support household deletion.
- Background syncing while the application is suspended or terminated.
- Persistent server-side idempotency across a mock API restart, since the supplied API keeps processed operation IDs in memory.
- Authentication and user management, since they are not required by the assignment.

### Lost Acknowledgement and Duplicate Recovery

The lost-ack scenario was manually tested. The server successfully applied the CREATE operation but dropped the response before the client received it.

- The client retained the original `op_id` and retried the same operation.
- The server returned `duplicate` with the previously assigned server ID, confirming that the operation was not applied twice.
- During local ID mapping, a conflict was detected because the mock API reused `hh-0031` after its restart, while the local database already associated that ID with another household.
- A `ServerIdMappingConflictException` was added to prevent overwriting an existing mapping or corrupting local data.

**Limitation:** The server-side duplicate protection was verified, but complete client-side recovery could not be verified in this test because the mock API reused an ID after restarting. In production, server-generated IDs should remain unique and stable across restarts.