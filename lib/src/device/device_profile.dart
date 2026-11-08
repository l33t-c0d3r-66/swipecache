import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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
  static SwipeDeviceProfile detect() {
    int? ram;
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        ram = parseMemInfo(File('/proc/meminfo').readAsStringSync());
      } else if (Platform.isIOS || Platform.isMacOS) {
        ram = _darwinMemSize();
      }
    } catch (_) {}
    var cores = 0;
    try {
      cores = Platform.numberOfProcessors;
    } catch (_) {}
    return SwipeDeviceProfile(totalRamBytes: ram, cpuCores: cores);
  }

  /// Extracts `MemTotal` (in bytes) from `/proc/meminfo` content.
  static int? parseMemInfo(String content) {
    final match = RegExp(r'^MemTotal:\s+(\d+)\s*kB', multiLine: true)
        .firstMatch(content);
    if (match == null) return null;
    return int.parse(match.group(1)!) * 1024;
  }

  static int? _darwinMemSize() {
    final sysctl = DynamicLibrary.process().lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Void>, Pointer<Size>,
            Pointer<Void>, Size),
        int Function(Pointer<Utf8>, Pointer<Void>, Pointer<Size>, Pointer<Void>,
            int)>('sysctlbyname');
    final name = 'hw.memsize'.toNativeUtf8();
    final value = calloc<Uint64>();
    final size = calloc<Size>()..value = sizeOf<Uint64>();
    try {
      final result = sysctl(name, value.cast(), size, nullptr, 0);
      return result == 0 && value.value > 0 ? value.value : null;
    } finally {
      calloc
        ..free(name)
        ..free(value)
        ..free(size);
    }
  }

  @override
  String toString() {
    final ram = totalRamBytes == null
        ? '?'
        : '${(totalRamBytes! / _gb).toStringAsFixed(1)}GB';
    return 'SwipeDeviceProfile(ram: $ram, cores: $cpuCores, tier: ${tier.name})';
  }
}
