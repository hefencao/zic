import 'dart:typed_data';

/// Streaming RIFF/WebP frame-boundary tracker used only for network flow credit.
///
/// This parser does not decode WebP and never decides animation semantics. It
/// simply counts complete ANMF chunks in a byte stream that begins at file
/// offset zero. Static WebP (no ANMF), malformed input, and non-WebP input never
/// become flow-blocked through this tracker; authoritative media classification
/// remains owned by DecodeSession.
final class WebpFramePrefixTracker {
  final List<int> _header = <int>[];
  var _riffHeaderComplete = false;
  var _unsupported = false;
  var _payloadRemaining = 0;
  var _padRemaining = 0;
  var _currentAnmf = false;
  var _completedFrames = 0;
  var _bytesConsumed = 0;

  int get completedFrames => _completedFrames;
  int get bytesConsumed => _bytesConsumed;
  bool get unsupported => _unsupported;

  void add(List<int> bytes) {
    if (bytes.isEmpty || _unsupported) return;
    var cursor = 0;
    while (cursor < bytes.length && !_unsupported) {
      if (!_riffHeaderComplete) {
        final need = 12 - _header.length;
        final take = _min(need, bytes.length - cursor);
        _header.addAll(bytes.sublist(cursor, cursor + take));
        cursor += take;
        _bytesConsumed += take;
        if (_header.length < 12) continue;
        if (!_matches(_header, 0, 'RIFF') || !_matches(_header, 8, 'WEBP')) {
          _unsupported = true;
          _header.clear();
          return;
        }
        _riffHeaderComplete = true;
        _header.clear();
        continue;
      }

      if (_payloadRemaining > 0) {
        final take = _min(_payloadRemaining, bytes.length - cursor);
        cursor += take;
        _bytesConsumed += take;
        _payloadRemaining -= take;
        if (_payloadRemaining == 0 && _currentAnmf) {
          _completedFrames++;
        }
        continue;
      }

      if (_padRemaining > 0) {
        final take = _min(_padRemaining, bytes.length - cursor);
        cursor += take;
        _bytesConsumed += take;
        _padRemaining -= take;
        continue;
      }

      final need = 8 - _header.length;
      final take = _min(need, bytes.length - cursor);
      _header.addAll(bytes.sublist(cursor, cursor + take));
      cursor += take;
      _bytesConsumed += take;
      if (_header.length < 8) continue;

      _currentAnmf = _matches(_header, 0, 'ANMF');
      final size = _uint32le(_header, 4);
      _payloadRemaining = size;
      _padRemaining = size.isOdd ? 1 : 0;
      _header.clear();
      if (_payloadRemaining == 0 && _currentAnmf) {
        _completedFrames++;
      }
    }
  }

  static int _min(int a, int b) => a < b ? a : b;

  static bool _matches(List<int> bytes, int offset, String ascii) {
    if (bytes.length < offset + ascii.length) return false;
    for (var i = 0; i < ascii.length; i++) {
      if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }

  static int _uint32le(List<int> bytes, int offset) =>
      ByteData.sublistView(Uint8List.fromList(bytes), offset, offset + 4)
          .getUint32(0, Endian.little);
}
