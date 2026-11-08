import 'dart:async';
import 'dart:math' as math;

import '../device/adaptive_policy.dart';
import '../util/logger.dart';
import '../util/mp4_inspector.dart';
import 'cache_config.dart';
import 'cache_entry.dart';
import 'cache_store.dart';

/// A request to warm the cache for one video.
class PrefetchRequest {
  const PrefetchRequest(
    this.url, {
    this.headers,
    this.headBytes,
    this.priority = 0,
  });

  final Uri url;
  final Map<String, String>? headers;

  /// Bytes from the start of the file to cache. `null` uses the default.
  final int? headBytes;

  /// Lower runs first.
  final int priority;
}

class _Task {
  _Task(this.key, this.request);
  final String key;
  PrefetchRequest request;
  bool cancelled = false;
}

/// Priority queue of partial ("head") downloads with bounded concurrency.
///
/// Only the first megabyte or so of upcoming videos is fetched – enough for an
/// instant start – instead of whole files, which wastes data on videos the
/// user swipes past. For MP4 files whose `moov` atom sits at the end, the
/// tail is fetched as well, since players need it before the first frame.
class Prefetcher {
  Prefetcher(this.store, this.config, this.policy);

  final CacheStore store;
  final SwipeCacheConfig config;

  /// Supplies the concurrency limit (fixed, or automatic from bandwidth and
  /// device class – re-read on every scheduling decision).
  final AdaptivePolicy policy;

  final List<_Task> _queue = [];
  final Map<String, _Task> _running = {};
  bool _paused = false;
  int completed = 0;

  bool get isPaused => _paused;
  int get pendingCount => _queue.length + _running.length;

  /// Replaces (or extends, with `replace: false`) the set of wanted
  /// downloads. Running downloads that are no longer wanted are cancelled.
  void schedule(List<PrefetchRequest> requests, {bool replace = true}) {
    final wanted = <String, PrefetchRequest>{};
    for (final request in requests) {
      wanted.putIfAbsent(store.keyFor(request.url), () => request);
    }
    if (replace) {
      _queue.clear();
      for (final task in _running.values) {
        if (!wanted.containsKey(task.key)) task.cancelled = true;
      }
    }
    for (final MapEntry(key: key, value: request) in wanted.entries) {
      final running = _running[key];
      if (running != null && !running.cancelled) {
        running.request = request;
        continue;
      }
      _queue.removeWhere((t) => t.key == key);
      _queue.add(_Task(key, request));
    }
    _queue.sort((a, b) => a.request.priority.compareTo(b.request.priority));
    _pump();
  }

  /// Temporarily stops starting new downloads (e.g. while the current video
  /// is still buffering and needs all the bandwidth).
  void pause() => _paused = true;

  void resume() {
    if (!_paused) return;
    _paused = false;
    _pump();
  }

  void cancelAll() {
    _queue.clear();
    for (final task in _running.values) {
      task.cancelled = true;
    }
  }

  void _pump() {
    while (!_paused &&
        _running.length < policy.maxConcurrentDownloads &&
        _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      if (_running.containsKey(task.key)) continue;
      _running[task.key] = task;
      unawaited(_run(task).whenComplete(() {
        if (identical(_running[task.key], task)) _running.remove(task.key);
        _pump();
      }));
    }
  }

  Future<void> _run(_Task task) async {
    final request = task.request;
    final entry = store.obtain(request.url, headers: request.headers);
    // Pinned while downloading so eviction cannot delete it under us.
    entry.pins++;
    try {
      await entry.ensureProbed();
      final total = entry.totalLength!;
      if (total == 0 || task.cancelled) return;
      final headBytes = request.headBytes ?? config.defaultPrefetchBytes;
      final headEnd = math.min(total, headBytes) - 1;
      final before = entry.cachedBytes;
      await _fetchRange(entry, 0, headEnd, task);
      if (task.cancelled) return;

      // Non fast-start MP4: the player reads the moov atom at the end first.
      if (entry.hasChunk(0) && config.maxTailPrefetchBytes > 0) {
        final head = await entry.read(0, entry.chunkEnd(0));
        final layout = inspectMp4Head(head, totalLength: total);
        final moov = layout.moovOffset;
        if (!layout.moovAtStart && moov != null && moov > headEnd) {
          final tailEnd = math.min(total - 1, moov + config.maxTailPrefetchBytes - 1);
          SwipeLog.v('Prefetching moov tail of ${entry.key} at $moov');
          await _fetchRange(entry, moov, tailEnd, task);
        }
      }
      entry.touch();
      // Count only prefetches that actually downloaded something.
      if (entry.cachedBytes > before) completed++;
    } catch (error) {
      SwipeLog.v('Prefetch failed for ${request.url}: $error');
    } finally {
      entry.pins--;
    }
  }

  Future<void> _fetchRange(CacheEntry entry, int start, int end, _Task task) async {
    final first = start ~/ entry.chunkSize;
    final last = end ~/ entry.chunkSize;
    var chunk = first;
    while (chunk <= last && !task.cancelled && !entry.isRemoved) {
      if (entry.hasChunk(chunk) || entry.isInflight(chunk)) {
        chunk++;
        continue;
      }
      var runEnd = chunk;
      while (runEnd < last &&
          runEnd - chunk + 1 < config.maxRunChunks &&
          !entry.hasChunk(runEnd + 1) &&
          !entry.isInflight(runEnd + 1)) {
        runEnd++;
      }
      await entry.fetchRun(chunk, runEnd, isCancelled: () => task.cancelled);
      chunk = runEnd + 1;
    }
  }
}
