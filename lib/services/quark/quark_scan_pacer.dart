import 'dart:async';

/// A scan may run for a long time. The budget is shared across consecutive
/// scans so switching to another mount cannot start a new burst.
class QuarkScanPacer {
  QuarkScanPacer({
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  })  : _now = now ?? DateTime.now,
        _delay = delay ?? Future<void>.delayed;

  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  DateTime? _nextRequest;
  int _requests = 0;

  Future<void> waitForTurn({
    Duration? interval,
    void Function(Duration)? onWait,
  }) async {
    final wait = _nextRequest?.difference(_now());
    if (wait != null && wait > Duration.zero) {
      onWait?.call(wait);
      await _delay(wait);
    }
    _requests++;
    final spacing = interval ??
        (_requests % 10 == 0
            ? const Duration(seconds: 30)
            : const Duration(seconds: 2));
    _nextRequest = _now().add(spacing);
  }
}
