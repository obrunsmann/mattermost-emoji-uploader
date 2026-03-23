import 'dart:math';

import 'async_mutex.dart';
import 'run_logger.dart';

class AdaptiveRateLimiter {
  AdaptiveRateLimiter({required double maxRequestsPerSecond, this.logger})
    : _maxRequestsPerSecond = max(1.0, maxRequestsPerSecond),
      _effectiveRate = max(1.0, maxRequestsPerSecond);

  final double _maxRequestsPerSecond;
  final AsyncMutex _mutex = AsyncMutex();
  final RunLogger? logger;

  DateTime _nextAllowedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _blockedUntil;
  double _effectiveRate;

  Future<void> acquire() {
    return _mutex.protect(() async {
      final now = DateTime.now();
      if (_blockedUntil != null && now.isBefore(_blockedUntil!)) {
        final wait = _blockedUntil!.difference(now);
        logger?.debug(
          'Rate limiter blocked window',
          context: {'wait_ms': wait.inMilliseconds},
        );
        await Future<void>.delayed(wait);
      }

      final nowAfterBlock = DateTime.now();
      if (nowAfterBlock.isBefore(_nextAllowedAt)) {
        final wait = _nextAllowedAt.difference(nowAfterBlock);
        await Future<void>.delayed(wait);
      }

      final spacingMillis = (1000 / _effectiveRate).ceil();
      _nextAllowedAt = DateTime.now().add(
        Duration(milliseconds: spacingMillis),
      );
    });
  }

  void updateFromHeaders(Map<String, String> headers, int statusCode) {
    final limit = _tryParseInt(headers['x-ratelimit-limit']);
    final remaining = _tryParseInt(headers['x-ratelimit-remaining']);
    final resetRaw = headers['x-ratelimit-reset'];
    final resetAt = _parseReset(resetRaw);

    if (limit != null && limit > 0) {
      final adjusted = min(_maxRequestsPerSecond, limit.toDouble() * 0.9);
      _effectiveRate = max(1.0, adjusted);
    }

    if (statusCode == 429 || (remaining != null && remaining <= 0)) {
      if (resetAt != null) {
        _blockedUntil = resetAt;
      } else {
        _blockedUntil = DateTime.now().add(const Duration(seconds: 1));
      }
    }
  }

  DateTime? _parseReset(String? raw) {
    final parsed = _tryParseInt(raw);
    if (parsed == null) {
      return null;
    }

    final nowEpochSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (parsed > nowEpochSeconds + 5) {
      return DateTime.fromMillisecondsSinceEpoch(parsed * 1000);
    }

    return DateTime.now().add(Duration(seconds: parsed));
  }

  int? _tryParseInt(String? value) {
    if (value == null) {
      return null;
    }
    return int.tryParse(value.trim());
  }
}
