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
    required this.decodeConcurrency,
    required this.uploadConcurrency,
  });

  /// Stable Reader pipeline profile shared by every source kind.
  ///
  /// Transport and plugin differences belong below the policy plane. Reader
  /// demand remains VibeVenera-style for local, Mihon, Venera and direct HTTP
  /// pages alike: seven ahead, three behind, decode-warm two ahead/one behind,
  /// and upload only current/transition through 5/3/2 lanes.
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
    decodeConcurrency: 3,
    uploadConcurrency: 2,
  );

  final RoleResolver windowResolver;
  final PolicyGuard guard;
  final HeuristicPolicy policy;
  final RetryPolicy retry;
  final int networkConcurrency;
  final int decodeConcurrency;
  final int uploadConcurrency;
}

ReaderPipelineProfile readerPipelineProfileFor(ChapterManifest chapter) {
  // Keep the manifest parameter in the composition API because future
  // transport capabilities may be selected atomically here. They must not
  // change the Reader demand window.
  return ReaderPipelineProfile.stable;
}
