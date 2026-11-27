import 'package:egov_household_survey/features/sync/domain/retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RetryPolicy policy({double random = 0.5}) {
    return RetryPolicy(random: () => random);
  }

  test('allows at most five retries', () {
    final retryPolicy = policy();

    expect(retryPolicy.allowsRetry(0), isTrue);
    expect(retryPolicy.allowsRetry(1), isTrue);
    expect(retryPolicy.allowsRetry(2), isTrue);
    expect(retryPolicy.allowsRetry(3), isTrue);
    expect(retryPolicy.allowsRetry(4), isTrue);
    expect(retryPolicy.allowsRetry(5), isFalse);
    expect(retryPolicy.allowsRetry(6), isFalse);
  });

  test('doubles the delay from 2 seconds', () {
    final retryPolicy = policy();

    expect(retryPolicy.nextDelay(attemptCount: 0), const Duration(seconds: 2));
    expect(retryPolicy.nextDelay(attemptCount: 1), const Duration(seconds: 4));
    expect(retryPolicy.nextDelay(attemptCount: 2), const Duration(seconds: 8));
    expect(retryPolicy.nextDelay(attemptCount: 3), const Duration(seconds: 16));
    expect(retryPolicy.nextDelay(attemptCount: 4), const Duration(seconds: 32));
  });

  test('caps the backoff delay at 60 seconds', () {
    final retryPolicy = policy();

    expect(retryPolicy.nextDelay(attemptCount: 5), const Duration(seconds: 60));
    expect(retryPolicy.nextDelay(attemptCount: 8), const Duration(seconds: 60));
  });

  test('keeps jitter inside plus or minus 20 percent', () {
    const base = Duration(seconds: 16);
    final lower = RetryPolicy(random: () => 0);
    final upper = RetryPolicy(random: () => 1);
    final middle = RetryPolicy(random: () => 0.25);

    expect(
      lower.nextDelay(attemptCount: 3),
      Duration(milliseconds: (base.inMilliseconds * 0.8).round()),
    );
    expect(
      upper.nextDelay(attemptCount: 3),
      Duration(milliseconds: (base.inMilliseconds * 1.2).round()),
    );
    expect(
      middle.nextDelay(attemptCount: 3),
      Duration(milliseconds: (base.inMilliseconds * 0.9).round()),
    );
    expect(
      RetryPolicy(random: () => 0).nextDelay(attemptCount: 5),
      const Duration(milliseconds: 48000),
    );
  });

  test('caps a jittered delay at 60 seconds', () {
    expect(
      RetryPolicy(random: () => 1).nextDelay(attemptCount: 5),
      const Duration(seconds: 60),
    );
    expect(
      RetryPolicy(
        random: () => 1,
      ).nextDelay(attemptCount: 5, retryAfter: const Duration(seconds: 90)),
      const Duration(seconds: 90),
    );
  });

  test('uses Retry-After as the minimum wait', () {
    final retryPolicy = policy();

    expect(
      retryPolicy.nextDelay(
        attemptCount: 0,
        retryAfter: const Duration(seconds: 5),
      ),
      const Duration(seconds: 5),
    );
    expect(
      retryPolicy.nextDelay(
        attemptCount: 2,
        retryAfter: const Duration(seconds: 5),
      ),
      const Duration(seconds: 8),
    );
    expect(
      RetryPolicy(
        random: () => 0,
      ).nextDelay(attemptCount: 0, retryAfter: const Duration(seconds: 5)),
      const Duration(seconds: 5),
    );
    expect(
      retryPolicy.nextDelay(
        attemptCount: 5,
        retryAfter: const Duration(seconds: 90),
      ),
      const Duration(seconds: 90),
    );
    expect(
      retryPolicy.nextDelay(attemptCount: 1, retryAfter: Duration.zero),
      const Duration(seconds: 4),
    );
  });
}
