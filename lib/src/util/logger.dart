import 'package:flutter/foundation.dart';

/// Log levels used by SwipeCache.
enum SwipeLogLevel { none, error, info, verbose }

/// Global logging switch. Defaults to errors only.
class SwipeLog {
  SwipeLog._();

  static SwipeLogLevel level = SwipeLogLevel.error;

  static void e(String message, [Object? error]) {
    if (level.index >= SwipeLogLevel.error.index) {
      debugPrint('[swipecache] ERROR $message${error != null ? ': $error' : ''}');
    }
  }

  static void i(String message) {
    if (level.index >= SwipeLogLevel.info.index) debugPrint('[swipecache] $message');
  }

  static void v(String message) {
    if (level.index >= SwipeLogLevel.verbose.index) {
      debugPrint('[swipecache] $message');
    }
  }
}
