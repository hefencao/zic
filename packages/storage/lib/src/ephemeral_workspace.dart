import 'dart:io';
import 'dart:typed_data';

import 'artifact.dart';
import 'cache_layout.dart';

/// Process-local storage workspace for a Reader session.
///
/// The App composes this object but does not own filesystem APIs. Artifact
/// creation remains lazy in the existing storage/session path, and disposal is
/// best-effort safe when the workspace has not written anything yet.
final class EphemeralCacheWorkspace {
  EphemeralCacheWorkspace._(this.rootPath) : layout = CacheLayout(rootPath);

  factory EphemeralCacheWorkspace.readerSession(String sessionId) {
    final safeSession = sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final root = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'zic-reader-$safeSession-$pid-$nonce';
    return EphemeralCacheWorkspace._(root);
  }

  /// App-private mutable transfer staging whose path survives process death.
  ///
  /// Android task removal can terminate Dart without running [dispose]. A
  /// fresh process must therefore be able to reopen the same deterministic
  /// partial path and let DownloadSession/decoder consume the bytes already
  /// present. Graceful owner shutdown still calls [dispose] after its normal
  /// durable handoff, so this is recoverable staging rather than a second
  /// persistent cache authority.
  factory EphemeralCacheWorkspace.recoverableTransfer(String stableId) {
    final safeId = stableId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final root = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'zic-transfer-$safeId';
    return EphemeralCacheWorkspace._(root);
  }

  final String rootPath;
  final CacheLayout layout;

  Future<Uint8List> readArtifact(Artifact artifact) => artifact.readBytes();

  Future<void> dispose() async {
    final root = Directory(rootPath);
    if (root.existsSync()) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
