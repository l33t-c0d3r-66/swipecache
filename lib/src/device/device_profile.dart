import 'device_probe_stub.dart'
    if (dart.library.io) 'device_probe_io.dart' as probe;

/// Coarse capability class of the device, used by automatic limits.
enum SwipeDeviceTier { low, mid, high }

/// Hardware facts relevant for video caching and decoding.
class SwipeDeviceProfile {
  const SwipeDeviceProfile({
    required this.totalRamBytes,
    required this.cpuCores,
  });

  /// Profile used when nothing could be measured (treated as mid-range).
  static const unknown = SwipeDeviceProfile(totalRamBytes: null, cpuCores: 0);

  /// Physical memory, `null` when it could not be determined.
  final int? totalRamBytes;
  final int cpuCores;

  static const _gb = 1024 * 1024 * 1024;

  /// low: < 3 GB RAM or ≤ 4 cores (entry-level Android),
  /// high: ≥ 6 GB RAM and ≥ 6 cores, mid: everything else or unknown.
  SwipeDeviceTier get tier {
    final ram = totalRamBytes;
    if (ram == null && cpuCores == 0) return SwipeDeviceTier.mid;
    // Allow ~10% for memory reserved by the kernel/GPU (a "3 GB" phone
    // reports about 2.8 GB).
    if ((ram != null && ram < 2.6 * _gb) ||
        (cpuCores > 0 && cpuCores <= 4)) {
      return SwipeDeviceTier.low;
    }
    if ((ram == null || ram >= 5.4 * _gb) && cpuCores >= 6) {
      return SwipeDeviceTier.high;
    }
    return SwipeDeviceTier.mid;
  }

  /// Reads the profile of the running device. Never throws.
  ///
  /// On the iOS simulator the Mac's memory and processors would be reported,
  /// so the profile of the simulated iPhone/iPad model is used instead.
  static SwipeDeviceProfile detect() {
    try {
      final (ram, cores) = probe.probeDevice();
      return SwipeDeviceProfile(totalRamBytes: ram, cpuCores: cores);
    } catch (_) {
      return unknown;
    }
  }

  /// Extracts `MemTotal` (in bytes) from `/proc/meminfo` content.
  static int? parseMemInfo(String content) {
    final match = RegExp(r'^MemTotal:\s+(\d+)\s*kB', multiLine: true)
        .firstMatch(content);
    if (match == null) return null;
    return int.parse(match.group(1)!) * 1024;
  }

  /// Typical hardware of an Apple model identifier such as `iPhone18,1`
  /// (used for simulators, which report the host Mac's hardware).
  static SwipeDeviceProfile forAppleModel(String identifier) {
    final match = RegExp(r'^(iPhone|iPad|iPod)(\d+),').firstMatch(identifier);
    if (match == null) {
      return const SwipeDeviceProfile(totalRamBytes: 4 * _gb, cpuCores: 6);
    }
    final family = match.group(1)!;
    final major = int.parse(match.group(2)!);
    if (family == 'iPad') {
      // iPad13+ (M1 and later) ship with 8 GB or more.
      return SwipeDeviceProfile(
        totalRamBytes: (major >= 13 ? 8 : 4) * _gb,
        cpuCores: major >= 13 ? 8 : 6,
      );
    }
    if (family == 'iPod') {
      return const SwipeDeviceProfile(totalRamBytes: 2 * _gb, cpuCores: 2);
    }
    final ramGb = switch (major) {
      < 10 => 2, // iPhone 7 and older
      10 => 2, // 8 / X
      11 => 3, // XS / XR
      12 || 13 || 14 => 4, // 11, 12, 13, 14
      15 => 6, // 14 Pro, 15
      _ => 8, // 15 Pro and newer
    };
    return SwipeDeviceProfile(
      totalRamBytes: ramGb * _gb,
      cpuCores: major >= 10 ? 6 : 2,
    );
  }

  @override
  String toString() {
    final ram = totalRamBytes == null
        ? '?'
        : '${(totalRamBytes! / _gb).toStringAsFixed(1)}GB';
    return 'SwipeDeviceProfile(ram: $ram, cores: $cpuCores, tier: ${tier.name})';
  }
}
