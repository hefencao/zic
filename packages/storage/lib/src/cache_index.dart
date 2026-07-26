import 'package:domain/domain.dart';

enum CacheState { partial, ready }

final class CacheRec {
  const CacheRec({
    required this.id,
    required this.state,
    required this.path,
    required this.bytes,
    required this.checksum,
    required this.createdUs,
    required this.touchedUs,
  });

  final DownloadId id;
  final CacheState state;
  final String path;
  final int bytes;
  final String checksum;
  final int createdUs;
  final int touchedUs;

  String get key => id.key;

  CacheRec copyWith({
    CacheState? state,
    String? path,
    int? bytes,
    String? checksum,
    int? createdUs,
    int? touchedUs,
  }) {
    return CacheRec(
      id: id,
      state: state ?? this.state,
      path: path ?? this.path,
      bytes: bytes ?? this.bytes,
      checksum: checksum ?? this.checksum,
      createdUs: createdUs ?? this.createdUs,
      touchedUs: touchedUs ?? this.touchedUs,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
        'download': id.toJson(),
        'state': state.name,
        'path': path,
        'bytes': bytes,
        'checksum': checksum,
        'createdUs': createdUs,
        'touchedUs': touchedUs,
      };

  factory CacheRec.fromJson(Map<String, Object?> json) {
    final rawId = json['download'];
    if (rawId is! Map) {
      throw const FormatException('download must be an object');
    }
    return CacheRec(
      id: DownloadId.fromJson(Map<String, Object?>.from(rawId)),
      state: CacheState.values.byName(json['state']! as String),
      path: json['path']! as String,
      bytes: json['bytes']! as int,
      checksum: json['checksum']! as String,
      createdUs: json['createdUs']! as int,
      touchedUs: json['touchedUs']! as int,
    );
  }
}

abstract interface class CacheIndex {
  Future<void> open();

  Future<CacheRec?> get(String key);

  Future<List<CacheRec>> list({CacheState? state});

  Future<void> put(CacheRec rec);

  Future<void> remove(String key);

  Future<int> totalBytes({CacheState? state});

  Future<void> close();
}

final class MemIndex implements CacheIndex {
  final Map<String, CacheRec> _records = <String, CacheRec>{};
  bool _closed = false;

  @override
  Future<void> open() async {
    _closed = false;
  }

  @override
  Future<CacheRec?> get(String key) async {
    _requireOpen();
    return _records[key];
  }

  @override
  Future<List<CacheRec>> list({CacheState? state}) async {
    _requireOpen();
    final records = _records.values
        .where((record) => state == null || record.state == state)
        .toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    return records;
  }

  @override
  Future<void> put(CacheRec rec) async {
    _requireOpen();
    _records[rec.key] = rec;
  }

  @override
  Future<void> remove(String key) async {
    _requireOpen();
    _records.remove(key);
  }

  @override
  Future<int> totalBytes({CacheState? state}) async {
    _requireOpen();
    return _records.values
        .where((record) => state == null || record.state == state)
        .fold<int>(0, (total, record) => total + record.bytes);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  void _requireOpen() {
    if (_closed) {
      throw StateError('cache index is closed');
    }
  }
}
