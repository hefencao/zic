import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';
import 'package:sessions/sessions.dart';

/// Composition profile for one Reader media pipeline.
///
/// This keeps source-specific transport characteristics out of the Reader UI.
/// The profile selects a stable demand window and independent scheduler lanes;
/// pages, sessions and transports remain owned by their existing layers.
final class ReaderPipelineProfile {
  const ReaderPipelineProfile({
    required this.windowResolver,
    required this.guard,
    required this.policy,
    required this.retry,
    required this.networkConcurrency,
    required this.localSourceConcurrency,
    required this.remoteSourceConcurrency,
    required this.decodeConcurrency,
    required this.uploadConcurrency,
  });

  /// Stable Reader pipeline profile shared by every source kind.
  ///
  /// Transport and plugin differences belong below the policy plane. Reader
  /// demand remains source-neutral for local, Mihon, Venera and direct HTTP
  /// pages alike: seven ahead, three behind, staged c/n/m/p decode waterlines,
  /// current/transition upload, one frozen last output, and 5/3/2 lanes.
  static const stable = ReaderPipelineProfile(
    windowResolver: RoleResolver(
      forwardEncodedPages: 7,
      backwardEncodedPages: 3,
      forwardDecodePages: 2,
      backwardDecodePages: 1,
      nearRadius: 0,
    ),
    guard: PolicyGuard(maxDownloadDemands: 11),
    policy: HeuristicPolicy(decodeWarmPages: true),
    retry: RetryPolicy(),
    networkConcurrency: 5,
    localSourceConcurrency: 2,
    remoteSourceConcurrency: 5,
    decodeConcurrency: 3,
    uploadConcurrency: 2,
  );

  final RoleResolver windowResolver;
  final PolicyGuard guard;
  final HeuristicPolicy policy;
  final RetryPolicy retry;
  /// Process-composition maximum across every active Reader page transfer.
  final int networkConcurrency;

  /// Per-source caps. Local SAF/file reads use two slots to avoid saturating
  /// one storage provider with large sequential copies; remote sources keep
  /// five until a source-specific capability lowers the bucket.
  final int localSourceConcurrency;
  final int remoteSourceConcurrency;
  final int decodeConcurrency;

  String downloadBucket(DownloadId id) {
    final scheme = id.canonicalUri.scheme.toLowerCase();
    if (scheme == 'file' || scheme == 'content' || scheme == 'asset') {
      return 'local';
    }
    return 'remote:${id.content.sourceId}';
  }

  int downloadBucketLimit(DownloadId id) {
    final scheme = id.canonicalUri.scheme.toLowerCase();
    return scheme == 'file' || scheme == 'content' || scheme == 'asset'
        ? localSourceConcurrency
        : remoteSourceConcurrency;
  }
  final int uploadConcurrency;
}

ReaderPipelineProfile readerPipelineProfileFor(ChapterManifest chapter) {
  // Keep the manifest parameter in the composition API because future
  // transport capabilities may be selected atomically here. They must not
  // change the Reader demand window.
  return ReaderPipelineProfile.stable;
}
