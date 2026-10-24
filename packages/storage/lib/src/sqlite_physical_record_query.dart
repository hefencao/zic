part of 'sqlite_index.dart';

const _physicalArtifactSelect = '''
  SELECT p.physical_key, p.physical_json, p.artifact_id,
         p.created_us AS binding_created_us,
         p.touched_us AS binding_touched_us,
         o.path, o.bytes, o.checksum, o.checksum_algorithm,
         o.storage_root_id
  FROM physical_media_artifact p
  JOIN artifact_object o ON o.artifact_id = p.artifact_id
''';

// Keys use existing primary indexes. Decode only selected rows, in bounded
// batches; yielding never crosses an open SQLite transaction or read cursor.
Future<List<T>> _readPhysicalRowsByKeys<T>(SqliteIndex index, {
  required String select,
  required String keyColumn,
  required String orderBy,
  required Iterable<String>? keys,
  required T Function(sql.Row) read,
}) => index._readRecords((db) async {
  if (keys == null) {
    return db.select('$select ORDER BY $orderBy')
        .map(read).toList(growable: false);
  }
  final selected = keys.toSet().toList(growable: false);
  final records = <T>[];
  for (var start = 0; start < selected.length; start += 400) {
    if (start > 0) await Future<void>.delayed(Duration.zero);
    final chunk = selected.sublist(start, (start + 400).clamp(0, selected.length));
    final slots = List.filled(chunk.length, '?').join(',');
    final rows = db.select('$select WHERE $keyColumn IN ($slots) '
        'ORDER BY $orderBy', chunk);
    records.addAll(rows.map(read));
  }
  return records;
});

PhysicalMediaArtifactRecord _readPhysicalArtifact(sql.Row row) {
  final decoded = jsonDecode(row['physical_json']! as String);
  if (decoded is! Map) {
    throw const FormatException('physical artifact identity is invalid');
  }
  final id = PhysicalMediaId.fromJson(Map<String, Object?>.from(decoded));
  if (row['physical_key']! as String != id.key) {
    throw const FormatException('physical artifact key/identity mismatch');
  }
  return PhysicalMediaArtifactRecord(
    id: id, artifactId: row['artifact_id']! as String,
    accessLocator: row['path']! as String, bytes: row['bytes']! as int,
    checksum: row['checksum']! as String,
    checksumAlgorithm: (row['checksum_algorithm'] as String?) ?? 'crc32',
    storageRootId: (row['storage_root_id'] as String?) ?? 'default',
    createdUs: row['binding_created_us']! as int,
    touchedUs: row['binding_touched_us']! as int,
  );
}
