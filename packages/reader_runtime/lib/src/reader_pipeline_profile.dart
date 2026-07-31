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

  static const standard = ReaderPipelineProfile(
    windowResolver: RoleResolver(),
    guard: PolicyGuard(),
    policy: HeuristicPolicy(),
    retry: RetryPolicy(),
    networkConcurrency: 3,
    decodeConcurrency: 2,
    uploadConcurrency: 1,
  );

  /// Stable VibeVenera-style encoded-byte window.
  ///
  /// Mirrors VibeVenera's stable asymmetric window: download seven pages in
  /// the reading direction and retain three behind. Only +2/-1 are decode-warm;
  /// the outer pages remain encoded-byte prefetch, preserving playback budgets
  /// and pipeline ownership.
  static const sourceStreaming = ReaderPipelineProfile(
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
  final hasSourceOwnedStreamingLocator = chapter.pages.any(
    (page) => page.uri.scheme == 'venera-resource',
  );
  return hasSourceOwnedStreamingLocator
      ? ReaderPipelineProfile.sourceStreaming
      : ReaderPipelineProfile.standard;
}
