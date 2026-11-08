import 'dart:typed_data';

/// Where the `moov` (index) atom of an MP4/MOV file lives.
class Mp4Layout {
  const Mp4Layout({required this.moovAtStart, this.moovOffset});

  /// `true` when the file is "fast start" (moov before mdat) or when the
  /// layout could not be determined (nothing extra to prefetch).
  final bool moovAtStart;

  /// Absolute offset of the `moov` box when it sits after `mdat`.
  final int? moovOffset;

  static const unknown = Mp4Layout(moovAtStart: true);
}

/// Inspects the top-level ISO-BMFF boxes found in [head] (the first bytes of a
/// file) to find out whether the player will need the tail of the file before
/// it can start. Non fast-start files are very common with user uploads; for
/// them prefetching only the head does not give an instant start.
Mp4Layout inspectMp4Head(Uint8List head, {int? totalLength}) {
  final data = ByteData.sublistView(head);
  var offset = 0;
  var sawFtyp = false;
  while (offset + 8 <= head.length) {
    var size = data.getUint32(offset);
    final type = String.fromCharCodes(head, offset + 4, offset + 8);
    var headerSize = 8;
    if (size == 1) {
      if (offset + 16 > head.length) break;
      size = data.getUint32(offset + 8) * 0x100000000 +
          data.getUint32(offset + 12);
      headerSize = 16;
    } else if (size == 0) {
      // Box extends to end of file.
      if (totalLength == null) break;
      size = totalLength - offset;
    }
    if (size < headerSize) break;

    if (offset == 0) {
      if (type != 'ftyp') return Mp4Layout.unknown; // Not an MP4 we know.
      sawFtyp = true;
    }
    if (type == 'moov') return const Mp4Layout(moovAtStart: true);
    if (type == 'mdat') {
      final after = offset + size;
      if (totalLength != null && after >= totalLength) {
        return Mp4Layout.unknown;
      }
      return Mp4Layout(moovAtStart: false, moovOffset: after);
    }
    offset += size;
  }
  return sawFtyp ? Mp4Layout.unknown : Mp4Layout.unknown;
}
