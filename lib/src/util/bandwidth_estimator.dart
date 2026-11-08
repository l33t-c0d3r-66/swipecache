/// Exponentially weighted moving average of observed download throughput.
///
/// Fed by real origin downloads, which is far more accurate than guessing from
/// the connectivity type (a congested Wi-Fi can be slower than 5G).
class BandwidthEstimator {
  BandwidthEstimator({this.alpha = 0.3, this.minSampleBytes = 64 * 1024});

  final double alpha;
  final int minSampleBytes;
  double? _bps;
  int _samples = 0;

  /// Estimated bits per second, or `null` before the first usable sample.
  double? get bitsPerSecond => _bps;
  int get sampleCount => _samples;

  void addSample(int bytes, Duration elapsed) {
    if (bytes < minSampleBytes || elapsed.inMicroseconds <= 0) return;
    final bps = bytes * 8 * 1e6 / elapsed.inMicroseconds;
    _bps = _bps == null ? bps : alpha * bps + (1 - alpha) * _bps!;
    _samples++;
  }

  void reset() {
    _bps = null;
    _samples = 0;
  }
}
