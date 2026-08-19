import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';

import 'browsing_direction_predictor.dart';
import 'demand.dart';
import 'decode_target.dart';
import 'heuristic_policy.dart';
import 'policy_guard.dart';
import 'role_window.dart';

final class PipelineDelta {
  const PipelineDelta({
    required this.plan,
    required this.diff,
    required this.window,
  });

  final DemandPlan plan;
  final DemandDiff diff;
  final RoleWindow window;
}

typedef PipelineCallback = void Function(PipelineDelta update);

final class PipelineController {
  PipelineController({
    required this.chapter,
    required DecodeTarget decodeTarget,
    required this.clock,
    required PipelineCallback onUpdate,
    this.traceSink = const NoopTraceSink(),
    this.windowResolver = const RoleResolver(),
    this.policy = const HeuristicPolicy(),
    this.guard = const PolicyGuard(),
  })  : _decodeTarget = decodeTarget,
        _onUpdate = onUpdate;

  final ChapterManifest chapter;
  DecodeTarget _decodeTarget;
  final MonoClock clock;
  final TraceSink traceSink;
  final RoleResolver windowResolver;
  final HeuristicPolicy policy;
  final PolicyGuard guard;
  final PipelineCallback _onUpdate;

  int _revision = 0;
  bool _decodeTargetDirty = false;
  DemandPlan _previous = DemandPlan.empty();
  Map<int, PageRole>? _previousRoles;
  int? _previousRetainedIndex;
  int? _currentIndex;
  int? _lastCurrentIndex;
  final BrowsingDirectionPredictor _directionPredictor =
      BrowsingDirectionPredictor();
  int _readDirection = 1;
  final Map<int, bool> _runtimeAnimatedPages = <int, bool>{};
  final Set<int> _runtimeWebpCostPages = <int>{};
  ReaderObs? _lastObservation;
  Set<int>? _previousVisibleIndexes;
  bool? _previousVerticalActive;
  int _animatedFlowStage = 0;

  int get revision => _revision;
  DemandPlan get currentPlan => _previous;
  DecodeTarget get decodeTarget => _decodeTarget;

  /// Updates only the decode/upload projection target. Physical download
  /// identity and Reader navigation are independent from viewport raster size.
  /// The next observation performs one incremental diff from the existing plan
  /// rather than detaching all demand to empty first.
  void updateDecodeTarget(DecodeTarget target) {
    if (_decodeTarget == target) return;
    _decodeTarget = target;
    _decodeTargetDirty = true;
  }

  void accept(ReaderObs observation) {
    final previousIndex = _currentIndex;
    if (previousIndex != null && previousIndex != observation.currentIndex) {
      _lastCurrentIndex = previousIndex;
      _animatedFlowStage = 0;
      final delta = observation.currentIndex - previousIndex;
      final directional = observation.interaction != Interaction.scrubbing &&
          observation.interaction != Interaction.jumping &&
          delta.abs() <= 5;
      _readDirection = _directionPredictor.record(
        delta: delta,
        directional: directional,
      );
    } else if (previousIndex == null) {
      _directionPredictor.reset(direction: 1);
      _readDirection = _directionPredictor.direction;
    }
    _currentIndex = observation.currentIndex;
    _lastObservation = observation;
    _replan(observation, force: false);
  }


  /// Records runtime encoded-content cost without promoting it to animation
  /// truth. Opaque plugin URIs (for example `venera-resource:`) cannot carry a
  /// useful extension/content-kind hint in the manifest, while the physical
  /// ingress can sniff WebP after only a small prefix. That fact is sufficient
  /// to enable conservative animated-WebP body flow; authoritative static vs
  /// animated classification remains decoder-owned and wins in
  /// [_animatedFlowActiveFor].
  bool observeWebpTransportCost({
    required int pageIndex,
    required bool webp,
  }) {
    if (pageIndex < 0 || pageIndex >= chapter.pages.length) return false;
    final before = _animatedFlowActiveFor(pageIndex);
    final changed = webp
        ? _runtimeWebpCostPages.add(pageIndex)
        : _runtimeWebpCostPages.remove(pageIndex);
    if (!changed) return false;
    if (pageIndex == _currentIndex &&
        before != _animatedFlowActiveFor(pageIndex)) {
      _animatedFlowStage = 0;
    }
    final observation = _lastObservation;
    if (observation != null) {
      _replan(observation, force: true);
    }
    return true;
  }

  bool classifyPage({required int pageIndex, required bool animated}) {
    if (pageIndex < 0 || pageIndex >= chapter.pages.length) return false;
    final beforeFlowActive = pageIndex == _currentIndex
        ? _animatedFlowActiveFor(pageIndex)
        : false;
    final current = _runtimeAnimatedPages[pageIndex];
    if (current == animated) return false;
    _runtimeAnimatedPages[pageIndex] = animated;
    if (pageIndex == _currentIndex &&
        beforeFlowActive != _animatedFlowActiveFor(pageIndex)) {
      _animatedFlowStage = 0;
    }
    final observation = _lastObservation;
    if (observation != null) {
      _replan(observation, force: true);
    }
    return true;
  }

  /// Raises animated-WebP transport frame credits from completed decode
  /// waterline evidence. The callback is revision-scoped so stale work from a
  /// previous page/session cannot increase the new current's body flow.
  bool observeDecodeWaterline({
    required int planRevision,
    required String stage,
  }) {
    final observation = _lastObservation;
    final current = _currentIndex;
    if (observation == null ||
        current == null ||
        planRevision != _revision ||
        !_animatedFlowActiveFor(current)) {
      return false;
    }
    final requested = policy.animatedPrefetchPolicy
        .expansionStageForWaterline(stage);
    if (requested <= _animatedFlowStage) return false;
    _animatedFlowStage = requested;
    _replan(observation, force: true);
    return true;
  }

  bool _animatedFlowActiveFor(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= chapter.pages.length) return false;
    final runtime = _runtimeAnimatedPages[pageIndex];
    if (runtime != null) return runtime;
    final page = chapter.pages[pageIndex];
    if (page.animatedHint) return true;
    // Manifest hints are conservative transport-cost evidence only.
    if (page.contentKindHint == ContentKindHint.webp ||
        page.uri.path.toLowerCase().endsWith('.webp')) {
      return true;
    }
    // Runtime sniffing closes the opaque-URI gap without claiming animation
    // truth. If this exact current page has been observed as WebP, use the
    // bounded body-flow policy until decoder classification says otherwise.
    if (_runtimeWebpCostPages.contains(pageIndex)) return true;
    // Once an animated page is authoritative, unresolved neighbors are
    // conservatively expensive. A runtime WebP observation provides the same
    // cost hint while the decoder is still working toward authoritative media
    // classification. Two authoritative static pages retain the existing
    // unresolved-static escape hatch.
    if (_runtimeAnimatedPages.values.any((animated) => animated)) return true;
    return !_assumeUnresolvedStatic && _runtimeWebpCostPages.isNotEmpty;
  }

  bool get _assumeUnresolvedStatic {
    var staticCount = 0;
    for (final animated in _runtimeAnimatedPages.values) {
      if (animated) return false;
      staticCount++;
    }
    return staticCount >= 2;
  }

  void _replan(ReaderObs observation, {required bool force}) {
    final window = windowResolver.resolve(
      chapter,
      observation,
      previousCurrentIndex: _lastCurrentIndex,
      readDirection: _readDirection,
    );
    final currentVisibleIndexes = observation.visibleCoverages
        .where((coverage) => coverage.fraction > 0)
        .map((coverage) => coverage.pageIndex)
        .toSet()
      ..add(observation.currentIndex);
    final visibleChanged =
        !_sameVisibleIndexes(_previousVisibleIndexes, currentVisibleIndexes);
    final verticalActive = observation.direction == ReadingDirection.vertical &&
        _isVerticalPresentationActive(observation.interaction);
    final verticalActiveChanged = _previousVerticalActive != verticalActive;
    final windowChanged =
        !_sameRoles(_previousRoles, window.roles) ||
        visibleChanged ||
        verticalActiveChanged ||
        _previousRetainedIndex != window.retainedIndex;
    if (!force && !_decodeTargetDirty && !windowChanged) {
      return;
    }
    final candidateRevision = _revision + 1;
    final animatedFlowActive =
        _animatedFlowActiveFor(observation.currentIndex);
    final animatedFlow = policy.animatedPrefetchPolicy.plan(
      chapter: chapter,
      observation: observation,
      window: window,
      active: animatedFlowActive,
      expansionStage: _animatedFlowStage,
      readDirection: _readDirection,
    );
    final proposal = policy.createPlan(
      revision: candidateRevision,
      chapter: chapter,
      observation: observation,
      window: window,
      decodeTarget: _decodeTarget,
      runtimeAnimatedPages: _runtimeAnimatedPages,
      assumeUnresolvedStatic: _assumeUnresolvedStatic,
      downloadFlow: animatedFlow,
      readDirection: _readDirection,
    );
    final plan = guard.enforce(proposal);
    final diff = DemandDiff.between(_previous, plan);

    // Runtime source/media evidence is observational state. It may change
    // without changing any authoritative scheduling request. Never promote
    // that diagnostic-only mutation into a new plan revision: revision churn
    // refreshes expiration metadata and used to make every decode/upload look
    // changed even when the policy result was identical.
    if (!windowChanged && !_decodeTargetDirty && diff.isEmpty) {
      _previousVisibleIndexes = currentVisibleIndexes;
      _previousVerticalActive = verticalActive;
      return;
    }

    _revision = candidateRevision;
    _previousRoles = Map<int, PageRole>.unmodifiable(window.roles);
    _previousRetainedIndex = window.retainedIndex;
    _previousVisibleIndexes = currentVisibleIndexes;
    _previousVerticalActive = verticalActive;
    _previous = plan;
    _decodeTargetDirty = false;

    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: observation.sessionId,
        kind: TraceEventKind.policyDecision,
        revision: _revision,
        payload: <String, Object?>{
          'downloads': plan.downloads.length,
          'decodes': plan.decodes.length,
          'uploads': plan.uploads.length,
          'staticWarmDecodes': plan.decodes.values
              .where((demand) => demand.reason.startsWith('heuristic:static-warm'))
              .length,
          'staticWarmUploads': plan.uploads.values
              .where((demand) => demand.reason.startsWith('heuristic:static-warm'))
              .length,
          'visibleIndexes': observation.visibleCoverages
              .map((coverage) => coverage.pageIndex)
              .toList(growable: false),
          'runtimeStaticPages': _runtimeAnimatedPages.values
              .where((animated) => !animated)
              .length,
          'runtimeWebpCostPages': _runtimeWebpCostPages.length,
          'assumeUnresolvedStatic': _assumeUnresolvedStatic,
          'animatedFlowActive': animatedFlow.active,
          'animatedFlowStage': animatedFlow.expansionStage,
          'animatedFlowFrameTargets': <String, int>{
            for (final entry in animatedFlow.targetFramesByIndex.entries)
              entry.key.toString(): entry.value,
          },
          'currentIndex': observation.currentIndex,
          'readDirection': _readDirection,
          'targetIndex': observation.targetCoverage?.pageIndex,
          'retainedIndex': window.retainedIndex,
          'interaction': observation.interaction.name,
        },
      ),
    );
    _onUpdate(PipelineDelta(plan: plan, diff: diff, window: window));
  }
}


bool _sameRoles(Map<int, PageRole>? previous, Map<int, PageRole> next) {
  if (previous == null || previous.length != next.length) {
    return false;
  }
  for (final entry in next.entries) {
    if (previous[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

bool _isVerticalPresentationActive(Interaction interaction) => switch (interaction) {
      Interaction.dragging ||
      Interaction.scrolling ||
      Interaction.settling => true,
      Interaction.idle ||
      Interaction.scrubbing ||
      Interaction.jumping => false,
    };

bool _sameVisibleIndexes(Set<int>? previous, Set<int> next) {
  if (previous == null || previous.length != next.length) {
    return false;
  }
  return previous.containsAll(next);
}
