import 'dart:convert';
import 'dart:io';

import 'package:domain/domain.dart';

import 'artifact.dart';

final class CacheLayout {
  const CacheLayout(this.root);

  final String root;

  String get partialDir => '${Directory(root).path}${Platform.pathSeparator}partial';
  String get finalDir => '${Directory(root).path}${Platform.pathSeparator}final';
  String get dbPath => '${Directory(root).path}${Platform.pathSeparator}cache.sqlite';

  Artifact artifactFor(DownloadId id) => _artifactForToken(tokenFor(id));

  /// Returns the pre-v2 artifact location used by older cache roots. Recovery
  /// may probe this path for an indexed record, but new writes always use
  /// [artifactFor] so delimiter collisions cannot select the same filename.
  Artifact legacyArtifactFor(DownloadId id) =>
      _artifactForToken(legacyTokenFor(id));

  String tokenFor(DownloadId id) => _fnv64(id.key);

  String legacyTokenFor(DownloadId id) => _fnv64(id.legacyKey);

  Artifact _artifactForToken(String token) => Artifact(
        partialPath: '$partialDir${Platform.pathSeparator}$token.part',
        finalPath: '$finalDir${Platform.pathSeparator}$token.bin',
      );
}

String _fnv64(String value) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
