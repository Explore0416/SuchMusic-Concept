import 'dart:async';

final _initCompleter = Completer<void>();

Future<void> get ensureInitialized => _initCompleter.future;

void markInitialized() {
  if (!_initCompleter.isCompleted) {
    _initCompleter.complete();
  }
}