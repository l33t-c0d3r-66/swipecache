import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'device_profile.dart';

/// Measures RAM (bytes) and CPU cores of the running device.
(int? ram, int cores) probeDevice() {
  if (Platform.isIOS) {
    // Simulators report the host Mac; use the simulated model instead.
    // Platform.environment is empty in Flutter iOS apps, so ask libc.
    final model = _getenv('SIMULATOR_MODEL_IDENTIFIER');
    if (model != null && model.isNotEmpty) {
      final profile = SwipeDeviceProfile.forAppleModel(model);
      return (profile.totalRamBytes, profile.cpuCores);
    }
    if (Platform.resolvedExecutable.contains('/CoreSimulator/')) {
      final profile = SwipeDeviceProfile.forAppleModel('iPhone16,1');
      return (profile.totalRamBytes, profile.cpuCores);
    }
  }
  int? ram;
  try {
    if (Platform.isAndroid || Platform.isLinux) {
      ram = SwipeDeviceProfile.parseMemInfo(
          File('/proc/meminfo').readAsStringSync());
    } else if (Platform.isIOS || Platform.isMacOS) {
      ram = _darwinMemSize();
    }
  } catch (_) {}
  var cores = 0;
  try {
    cores = Platform.numberOfProcessors;
  } catch (_) {}
  return (ram, cores);
}

String? _getenv(String name) {
  try {
    final getenv = DynamicLibrary.process()
        .lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)>('getenv');
    final key = name.toNativeUtf8();
    try {
      final value = getenv(key);
      return value == nullptr ? null : value.toDartString();
    } finally {
      calloc.free(key);
    }
  } catch (_) {
    return null;
  }
}

int? _darwinMemSize() {
  final sysctl = DynamicLibrary.process().lookupFunction<
      Int32 Function(
          Pointer<Utf8>, Pointer<Void>, Pointer<Size>, Pointer<Void>, Size),
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
