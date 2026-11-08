import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../cache/prefetch_request.dart';
import '../cache/swipe_cache.dart';
import '../device/adaptive_policy.dart';
import '../reel/reel_data.dart';
import 'swipe_feed_config.dart';
import 'swipe_player.dart';
import 'swipe_source.dart';

/// Brain of a swipeable video feed.
///
/// * keeps a small pool of initialised players around the current index
///   (instant swipes without exhausting hardware decoders),
/// * plays exactly one video at a time,
/// * prefetches the head of upcoming videos sized to the measured bandwidth,
/// * reacts to app lifecycle, visibility and memory pressure,
/// * asks for more items when the end of the list approaches.
class SwipeFeedController extends ChangeNotifier with WidgetsBindingObserver {
  SwipeFeedController({
    List<SwipeSource> sources = const [],
    int initialIndex = 0,
    this.config = const SwipeFeedConfig(),
    SwipeCache? cache,
    this.onLoadMore,
    this.onIndexChanged,
  })  : _cache = cache ?? SwipeCache.instance,
        _sources = List.of(sources),
        _index = sources.isEmpty ? 0 : initialIndex.clamp(0, sources.length - 1) {
    WidgetsBinding.instance.addObserver(this);
    _applyWindow();
    // If the cache is still starting, prefetch requests made above were
    // dropped; schedule them again once it is ready.
    if (!_cache.isReady) {
      unawaited(_cache.whenReady.then((_) {
        if (!_disposed && _visible) _schedulePrefetch();
      }));
    }
  }

  final SwipeFeedConfig config;
  final SwipeCache _cache;

  /// Called when the user approaches the end of the list. Append the next
  /// page with [appendSources] (set [hasMore] to `false` at the end).
  final Future<void> Function()? onLoadMore;

  final ValueChanged<int>? onIndexChanged;

  List<SwipeSource> _sources;
  int _index;
  final Map<String, SwipePlayer> _players = {};
  Timer? _settleTimer;
  PageController? _pageController;

  bool _appActive = true;
  bool _visible = true;
  bool _userPaused = false;
  bool _muted = false;
  double _speed = 1;
  bool _loadingMore = false;
  bool hasMore = true;
  bool _disposed = false;

  List<SwipeSource> get sources => List.unmodifiable(_sources);
  int get length => _sources.length;
  int get index => _index;
  bool get isEmpty => _sources.isEmpty;
  bool get isMuted => _muted;

  /// Playback speed of every video in the feed (1 = normal).
  double get playbackSpeed => _speed;
  bool get isLoadingMore => _loadingMore;

  /// `true` when the user paused the current video by tapping.
  bool get isUserPaused => _userPaused;
  bool get isVisible => _visible;

  /// Limits in force for this feed right now (automatic ones reflect the
  /// current device and network conditions).
  SwipeResolvedLimits get limits => _cache.policy.resolve(
        preloadAhead: config.preloadAhead,
        preloadBehind: config.preloadBehind,
        prefetchAhead: config.prefetchAhead,
        prefetchHeadBytes: config.prefetchHeadBytes,
      );

  /// Number of live players (decoders) in the pool.
  int get activePlayerCount => _players.length;

  /// Sources that currently own a player.
  Iterable<SwipeSource> get activeSources =>
      _players.values.map((p) => p.source);

  SwipeSource? get currentSource =>
      _index < _sources.length ? _sources[_index] : null;

  SwipePlayer? get currentPlayer {
    final source = currentSource;
    return source == null ? null : _players[source.id];
  }

  /// Player of the item at [index], if it is inside the preload window.
  SwipePlayer? playerAt(int index) {
    if (index < 0 || index >= _sources.length) return null;
    return _players[_sources[index].id];
  }

  bool get _shouldPlay =>
      config.autoplay && _appActive && _visible && !_userPaused;

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  /// Call from `PageView.onPageChanged` (done for you by `SwipeFeed`).
  void onPageChanged(int index) {
    if (_disposed || index == _index || index < 0 || index >= _sources.length) {
      return;
    }
    final previous = currentPlayer;
    _index = index;
    _userPaused = false;
    // Stop the old audio right away, even while the finger is still moving.
    if (previous != null) {
      unawaited(config.restartOnLeave ? previous.reset() : previous.pause());
    }
    final current = currentPlayer;
    if (current != null && current.isReady && _shouldPlay) {
      unawaited(current.play());
    }
    _watchCurrent();
    onIndexChanged?.call(index);
    notifyListeners();

    _settleTimer?.cancel();
    _settleTimer = Timer(config.settleDelay, _applyWindow);
    _maybeLoadMore();
  }

  /// Programmatic navigation. Requires an attached `SwipeFeed`.
  Future<void> animateTo(
    int index, {
    Duration duration = const Duration(milliseconds: 350),
    Curve curve = Curves.easeOutCubic,
  }) async {
    final controller = _pageController;
    if (controller == null || !controller.hasClients) return;
    await controller.animateToPage(index, duration: duration, curve: curve);
  }

  void jumpTo(int index) {
    final controller = _pageController;
    if (controller != null && controller.hasClients) {
      controller.jumpToPage(index);
    } else if (index >= 0 && index < _sources.length) {
      _index = index;
      _applyWindow();
    }
  }

  /// Used by `SwipeFeed` to enable [animateTo]/[jumpTo].
  void attachPageController(PageController? controller) {
    _pageController = controller;
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  /// Replaces the list. Players of items that are still present are kept, so
  /// a refresh that keeps the current item does not interrupt playback.
  void setSources(List<SwipeSource> sources, {int? index}) {
    if (_disposed) return;
    final currentId = currentSource?.id;
    _sources = List.of(sources);
    if (index != null) {
      _index = _sources.isEmpty ? 0 : index.clamp(0, _sources.length - 1);
    } else {
      final kept = _sources.indexWhere((s) => s.id == currentId);
      _index = kept >= 0 ? kept : 0;
    }
    hasMore = true;
    _applyWindow();
    if (_pageController?.hasClients ?? false) {
      _pageController!.jumpToPage(_index);
    }
  }

  void appendSources(List<SwipeSource> sources) {
    if (_disposed || sources.isEmpty) return;
    final known = _sources.map((s) => s.id).toSet();
    _sources.addAll(sources.where((s) => known.add(s.id)));
    _applyWindow();
  }

  /// The item with [id], or `null`.
  SwipeSource? sourceById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  /// Replaces the display data of item [id] (caption, counters...). The
  /// video keeps playing: `id` and `url` can not change this way.
  void updateSource(String id, SwipeSource Function(SwipeSource source) update) {
    if (_disposed) return;
    final at = _sources.indexWhere((s) => s.id == id);
    if (at < 0) return;
    final old = _sources[at];
    final updated = update(old);
    assert(updated.id == old.id && updated.url == old.url,
        'updateSource can not change id or url');
    _sources[at] = updated;
    notifyListeners();
  }

  /// Updates the reel data of item [id], e.g. after a like from elsewhere:
  ///
  /// ```dart
  /// controller.updateReel(id, (r) => r.copyWith(commentCount: r.commentCount + 1));
  /// ```
  void updateReel(String id, SwipeReelData Function(SwipeReelData reel) update) {
    updateSource(id,
        (s) => s.copyWith(reel: update(s.reel ?? const SwipeReelData())));
  }

  void removeSource(String id) {
    final at = _sources.indexWhere((s) => s.id == id);
    if (at < 0) return;
    _sources.removeAt(at);
    if (at < _index || _index >= _sources.length) {
      _index = math.max(0, _index - 1);
    }
    _applyWindow();
  }

  void _maybeLoadMore() {
    final loader = onLoadMore;
    if (loader == null || !hasMore || _loadingMore) return;
    if (_index < _sources.length - config.loadMoreThreshold) return;
    _loadingMore = true;
    notifyListeners();
    unawaited(loader().whenComplete(() {
      _loadingMore = false;
      if (!_disposed) notifyListeners();
    }));
  }

  // ---------------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------------

  void play() {
    _userPaused = false;
    _syncPlayback();
    notifyListeners();
  }

  void pause() {
    _userPaused = true;
    _syncPlayback();
    notifyListeners();
  }

  void togglePlay() => _userPaused ? play() : pause();

  /// Plays every video at [speed] (e.g. 0.5, 1.5, 2) until changed again.
  void setPlaybackSpeed(double speed) {
    assert(speed > 0);
    _speed = speed;
    for (final player in _players.values) {
      unawaited(player.setPlaybackSpeed(speed));
    }
    notifyListeners();
  }

  void setMuted(bool muted) {
    _muted = muted;
    for (final player in _players.values) {
      unawaited(player.setMuted(muted));
    }
    notifyListeners();
  }

  /// Tell the controller whether the feed is on screen (e.g. tab switches,
  /// pushed routes). Hidden feeds keep their players but stay silent.
  void setVisible(bool visible) {
    if (_visible == visible || _disposed) return;
    _visible = visible;
    if (visible) {
      // Rebuild the window: neighbours may have been released, and another
      // feed may have replaced our prefetch queue meanwhile.
      _applyWindow();
    } else {
      _syncPlayback();
      if (config.releaseWhenHidden) {
        // Free decoders for the feed that is now on top (e.g. a pushed
        // reels page) - low-end Android devices only have a few.
        final current = currentSource?.id;
        _disposePlayers((id) => id != current);
      }
      notifyListeners();
    }
  }

  void _syncPlayback() {
    final current = currentPlayer;
    for (final player in _players.values) {
      if (identical(player, current)) {
        unawaited(_shouldPlay ? player.play() : player.pause());
      } else if (player.wantsToPlay) {
        unawaited(player.pause());
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Window management
  // ---------------------------------------------------------------------------

  void _applyWindow() {
    _settleTimer?.cancel();
    _settleTimer = null;
    if (_disposed) return;
    if (_sources.isEmpty) {
      _disposePlayers((_) => true);
      notifyListeners();
      return;
    }
    _index = _index.clamp(0, _sources.length - 1);

    // Initialisation order: current, then ahead (likely next), then behind.
    final policy = _cache.policy;
    final ahead = policy.preloadAhead(config.preloadAhead);
    final behind = policy.preloadBehind(config.preloadBehind);
    final order = <int>[_index];
    for (var i = 1; i <= ahead; i++) {
      order.add(_index + i);
    }
    for (var i = 1; i <= behind; i++) {
      order.add(_index - i);
    }
    final window = order.where((i) => i >= 0 && i < _sources.length).toList();
    final wanted = {for (final i in window) _sources[i].id};

    _disposePlayers((id) => !wanted.contains(id));

    for (final i in window) {
      final source = _sources[i];
      final player = _players.putIfAbsent(
        source.id,
        () => SwipePlayer(
          source: source,
          cache: _cache,
          config: config,
          muted: _muted,
          speed: _speed,
          onAutoplayBlocked: () {
            if (!_muted && !_disposed) setMuted(true);
          },
        ),
      );
      if (i == _index) {
        if (_shouldPlay) {
          unawaited(player.play());
        } else {
          unawaited(player.initialize());
        }
      } else {
        unawaited(player.initialize());
        if (player.wantsToPlay) unawaited(player.pause());
      }
    }

    if (!_visible && config.releaseWhenHidden) {
      final current = currentSource?.id;
      _disposePlayers((id) => id != current);
    }
    _cache.protect(window.map((i) => _sources[i].url), owner: this);
    if (_visible) _schedulePrefetch();
    _watchCurrent();
    notifyListeners();
  }

  void _schedulePrefetch() {
    final policy = _cache.policy;
    final count = policy.prefetchAhead(config.prefetchAhead);
    final headBytes = policy.prefetchHeadBytes(config.prefetchHeadBytes);
    final requests = <PrefetchRequest>[];
    var priority = 0;
    void add(int i) {
      if (i < 0 || i >= _sources.length) return;
      final source = _sources[i];
      final uri = Uri.tryParse(source.url);
      if (uri == null || !uri.hasScheme || uri.scheme == 'file') return;
      requests.add(PrefetchRequest(uri,
          headers: source.headers,
          headBytes: headBytes,
          priority: priority++,
          formatHint: source.formatHint));
    }

    for (var i = 1; i <= count; i++) {
      add(_index + i);
    }
    add(_index - 1);
    _cache.schedulePrefetch(requests);
  }

  SwipePlayer? _watched;

  /// Follows the current player: background prefetching is held while it is
  /// loading or buffering so it gets all the bandwidth, and resumed once it
  /// plays smoothly.
  void _watchCurrent() {
    final current = currentPlayer;
    if (identical(current, _watched)) {
      _onCurrentChanged();
      return;
    }
    _watched?.removeListener(_onCurrentChanged);
    _watched = current;
    current?.addListener(_onCurrentChanged);
    _onCurrentChanged();
  }

  void _onCurrentChanged() {
    final current = _watched;
    if (current == null || current.isDisposed) {
      _cache.resumePrefetch();
      return;
    }
    final starving = !current.isReady && current.status != SwipePlayerStatus.error;
    if (config.pausePrefetchUntilReady && (starving || current.isBuffering)) {
      _cache.pausePrefetch();
    } else {
      _cache.resumePrefetch();
    }
  }

  void _disposePlayers(bool Function(String id) test) {
    final ids = _players.keys.where(test).toList();
    for (final id in ids) {
      _players.remove(id)?.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // System events
  // ---------------------------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _appActive) return;
    _appActive = active;
    if (active) {
      // The proxy may have lost its socket while suspended (iOS); players
      // that hit it meanwhile recover on their own.
      unawaited(_cache.ensureHealthy().whenComplete(() {
        if (!_disposed) _syncPlayback();
      }));
    } else {
      _syncPlayback();
    }
  }

  @override
  void didHaveMemoryPressure() {
    final current = currentSource?.id;
    _disposePlayers((id) => id != current);
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _settleTimer?.cancel();
    _watched?.removeListener(_onCurrentChanged);
    _watched = null;
    _disposePlayers((_) => true);
    _cache.cancelPrefetch();
    _cache.resumePrefetch();
    _cache.unprotect(this);
    super.dispose();
  }
}
