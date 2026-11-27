AI Development Log

1. AI Tools Used

ChatGPT: Used for understanding assignment requirements, planning the application architecture, reviewing implementation decisions, debugging guidance, and preparing test scenarios.

Cursor: Used to implement Flutter features, update repositories and sync logic, generate tests, investigate errors, and make focused code changes.

AI-generated changes were reviewed and tested during development rather than accepted without verification.

2. Important Prompts Used

The following are representative prompts used during development.

Database and Household Management

Implement SQLite tables for households and sync operations.

Ensure household changes and their corresponding sync operations are saved in a single database transaction.

Add repository methods for household creation, updates, and operation sequence management.

Add tests for transaction rollback and per-household operation ordering.

API Integration

Implement an API service for the supplied mock API endpoints.

Handle API responses, HTTP errors, request timeouts, and retry-related response information.

Integrate initial server household loading while preserving existing local records and queued operations.

Offline and Sync Implementation

Implement persistent Online/Offline settings.

Ensure no API requests are made while Offline mode is enabled.

Implement a sync engine that processes operations in per-household sequence order.

Use stable operation IDs across retries and handle duplicate responses.

Implement exponential backoff, retry limits, jitter, and Retry-After support.

Queue Handling and Testing

Implement separate states for pending, retrying, parked, blocked, rejected, and completed operations.

Prevent later operations from being sent when an earlier operation for the same household is parked or rejected.

Add Retry and Dismiss actions with the appropriate queue updates.

Add unit tests for retry handling, operation blocking, and rejected operation dismissal.

3. Mistakes and Issues Identified

Issue 1: Later Operations Were Not Blocked

What happened: During manual testing, a household had a parked CREATE operation, but a subsequent UPDATE operation was still displayed as Pending.

How it was identified: I inspected the queue after creating an update for a household with an earlier parked operation.

Correction: The queue logic was updated to mark later operations as Blocked when an earlier operation is parked or rejected. Reconciliation was also added when loading households and starting sync.

Issue 2: Duplicate CREATE Response Without Server ID

What happened: During Retry testing, the backend returned HTTP 200 with a duplicate status, no server household ID, and a validation error. The sync engine treated it as completed and attempted to map a missing server ID, leaving the operation pending.

How it was identified: I examined the API response and application logs after tapping Retry.

Correction: A focused fix was prepared to prevent a CREATE operation with a duplicate response, missing server ID, and error from being incorrectly completed. It should instead remain visible as an operation requiring attention. Final verification of this fix is pending.

Issue 3: Invalid Household Data

What happened: A manually created test household used a member count of 88. The backend rejected it because the accepted range is 1–30.

How it was identified: The API returned HTTP 400 during manual sync testing.

Correction: The rejected operation was retained for user attention, and the validation failure was used to investigate the Retry and Dismiss behaviour.

Issue 4: Test Coverage for Queue Behaviour

What happened: Initial tests did not cover all the cases involving operations created behind parked or rejected operations.

How it was identified: Reviewing the manual testing results exposed queue-state cases that were not covered by the existing tests.

Correction: Additional tests were added for operation blocking, retry, dismissal, and queue reconciliation.

Issue 5: Server ID Mapping Conflict After Mock API Restart

During lost-ack testing, the mock API restarted and reused the server ID `hh-0031`, which was already mapped to another local household. This exposed a gap in the original local ID mapping logic.

I reviewed the application logs and database state to identify the cause. I used Cursor to add a `ServerIdMappingConflictException` check before updating the local mapping. I then verified the fix with regression tests, and all 115 tests passed.

The conflict guard prevents local data corruption, but the complete recovery flow remains unverified for this particular test because the mock API reused an ID after restarting.

4. How AI Output Was Reviewed

Reviewed generated code changes and their effect on existing functionality.

Ran flutter analyze to check for static analysis issues.

Ran flutter test after implementation changes.

Used the supplied mock API and its chaos scenarios for manual testing.

Inspected application logs and API responses to investigate unexpected behaviour.

Used manual testing to identify issues that were not initially covered by generated tests.