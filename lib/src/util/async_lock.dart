import 'dart:async';

/// Minimal FIFO async mutex.
class AsyncLock {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _tail;
    _tail = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }
}
