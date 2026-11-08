import 'dart:convert';

/// 64-bit FNV-1a hash rendered as a 16 char hex string.
///
/// Used to derive stable, filesystem-safe cache keys from URLs without pulling
/// in a crypto dependency. Collisions are astronomically unlikely for the
/// number of entries a video cache holds.
String fnv1a64Hex(String input) {
  // Two 32-bit halves keep the arithmetic exact on every platform.
  var hi = 0xcbf29ce4;
  var lo = 0x84222325;
  for (final byte in utf8.encode(input)) {
    lo ^= byte;
    // Multiply (hi:lo) by the FNV prime 0x00000100_000001B3.
    final loMul = lo * 0x1b3;
    final carry = loMul ~/ 0x100000000;
    final newLo = loMul & 0xffffffff;
    final newHi = (hi * 0x1b3 + (lo << 8) + carry) & 0xffffffff;
    hi = newHi;
    lo = newLo;
  }
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}
