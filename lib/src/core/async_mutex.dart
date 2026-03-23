import 'dart:async';

class AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> protect<T>(FutureOr<T> Function() action) {
    final completer = Completer<void>();
    final previous = _tail;
    _tail = completer.future;

    return previous.then((_) => action()).whenComplete(() {
      completer.complete();
    });
  }
}
