import 'dart:math' as math;

/// Returns a number from 0 through 1 inclusive.
typedef RetryRandom = double Function();

/// Decides whether a failed sync operation may be tried again, and how long
/// to wait. [attemptCount] is the number of attempts already made.
class RetryPolicy {
  RetryPolicy({RetryRandom? random})
    : _random = random ?? math.Random().nextDouble;

  static const int maxAttempts = 5;
  static const Duration initialDelay = Duration(seconds: 2);
  static const int multiplier = 2;
  static const Duration maxDelay = Duration(seconds: 60);
  static const double jitterFraction = 0.2;

  final RetryRandom _random;

  bool allowsRetry(int attemptCount) {
    return attemptCount >= 0 && attemptCount < maxAttempts;
  }

  Duration nextDelay({required int attemptCount, Duration? retryAfter}) {
    var delay = _applyJitter(_baseDelay(attemptCount));
    if (delay > maxDelay) {
      delay = maxDelay;
    }
    if (retryAfter != null && retryAfter > delay) {
      return retryAfter;
    }
    return delay;
  }

  Duration _baseDelay(int attemptCount) {
    var delay = initialDelay;
    final steps = attemptCount < 0 ? 0 : attemptCount;
    for (var step = 0; step < steps; step++) {
      final next = delay * multiplier;
      if (next >= maxDelay) {
        return maxDelay;
      }
      delay = next;
    }
    return delay;
  }

  Duration _applyJitter(Duration base) {
    final unit = _random().clamp(0.0, 1.0);
    final factor = 1 + ((unit * 2) - 1) * jitterFraction;
    return Duration(milliseconds: (base.inMilliseconds * factor).round());
  }
}
