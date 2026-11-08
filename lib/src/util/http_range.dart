/// A resolved, inclusive byte range.
class ByteRange {
  const ByteRange(this.start, this.end);

  /// First byte offset (inclusive).
  final int start;

  /// Last byte offset (inclusive).
  final int end;

  int get length => end - start + 1;

  @override
  String toString() => 'ByteRange($start-$end)';

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Result of parsing a `Range` request header against a known resource size.
sealed class RangeParseResult {
  const RangeParseResult();
}

/// No (usable) range header: serve the full resource with `200`.
class FullContent extends RangeParseResult {
  const FullContent();
}

/// A satisfiable single range: serve with `206`.
class PartialContent extends RangeParseResult {
  const PartialContent(this.range);
  final ByteRange range;
}

/// The range can not be satisfied: respond with `416`.
class UnsatisfiableRange extends RangeParseResult {
  const UnsatisfiableRange();
}

/// Parses an HTTP `Range` header (RFC 9110 §14.2) for a resource of
/// [totalLength] bytes. Only the first range of a multi-range request is
/// honoured, which is what media players send in practice.
RangeParseResult parseRangeHeader(String? header, int totalLength) {
  if (header == null) return const FullContent();
  final value = header.trim();
  if (!value.toLowerCase().startsWith('bytes=')) return const FullContent();
  final spec = value.substring(6).split(',').first.trim();
  final dash = spec.indexOf('-');
  if (dash < 0) return const FullContent();

  final startStr = spec.substring(0, dash).trim();
  final endStr = spec.substring(dash + 1).trim();

  if (startStr.isEmpty) {
    // Suffix range: last N bytes.
    final suffix = int.tryParse(endStr);
    if (suffix == null) return const FullContent();
    if (suffix <= 0 || totalLength == 0) return const UnsatisfiableRange();
    final start = suffix >= totalLength ? 0 : totalLength - suffix;
    return PartialContent(ByteRange(start, totalLength - 1));
  }

  final start = int.tryParse(startStr);
  if (start == null || start < 0) return const FullContent();
  if (start >= totalLength) return const UnsatisfiableRange();

  var end = totalLength - 1;
  if (endStr.isNotEmpty) {
    final parsed = int.tryParse(endStr);
    if (parsed == null || parsed < start) return const FullContent();
    if (parsed < end) end = parsed;
  }
  return PartialContent(ByteRange(start, end));
}

/// Parsed `Content-Range: bytes a-b/total` response header.
class ContentRange {
  const ContentRange(this.start, this.end, this.total);
  final int start;
  final int end;

  /// `null` when the server reported `*` (unknown).
  final int? total;
}

ContentRange? parseContentRange(String? header) {
  if (header == null) return null;
  final match =
      RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)').firstMatch(header.trim());
  if (match == null) return null;
  return ContentRange(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    match.group(3) == '*' ? null : int.parse(match.group(3)!),
  );
}
