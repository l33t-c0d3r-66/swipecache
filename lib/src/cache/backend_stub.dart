import '../device/adaptive_policy.dart';
import 'cache_backend.dart';
import 'cache_config.dart';

/// No disk cache without `dart:io` (web).
CacheBackend? createCacheBackend(
        SwipeCacheConfig config, AdaptivePolicy policy) =>
    null;
