import 'dart:convert';
import 'dart:typed_data';

/// Compact record of which fixed-size chunks of a file are on disk.
class ChunkBitmap {
  ChunkBitmap(this.chunkCount) : _bits = Uint8List((chunkCount + 7) >> 3);

  ChunkBitmap._(this.chunkCount, this._bits);

  factory ChunkBitmap.decode(int chunkCount, String encoded) {
    final bytes = base64.decode(encoded);
    final expected = (chunkCount + 7) >> 3;
    if (bytes.length != expected) return ChunkBitmap(chunkCount);
    final bitmap = ChunkBitmap._(chunkCount, Uint8List.fromList(bytes));
    bitmap._completed = bitmap._countSet();
    return bitmap;
  }

  final int chunkCount;
  final Uint8List _bits;
  int _completed = 0;

  int get completedCount => _completed;
  bool get isComplete => _completed == chunkCount;

  bool has(int index) =>
      index >= 0 &&
      index < chunkCount &&
      (_bits[index >> 3] & (1 << (index & 7))) != 0;

  /// Marks [index] as present. Returns `false` if it already was.
  bool set(int index) {
    if (index < 0 || index >= chunkCount || has(index)) return false;
    _bits[index >> 3] |= 1 << (index & 7);
    _completed++;
    return true;
  }

  /// `true` when every chunk in `[first, last]` is present.
  bool hasAll(int first, int last) {
    for (var i = first; i <= last; i++) {
      if (!has(i)) return false;
    }
    return true;
  }

  String encode() => base64.encode(_bits);

  int _countSet() {
    var count = 0;
    for (var i = 0; i < chunkCount; i++) {
      if (has(i)) count++;
    }
    return count;
  }
}
