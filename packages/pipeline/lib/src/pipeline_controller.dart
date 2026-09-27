import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';

import 'browsing_direction_predictor.dart';
import 'decode_target.dart';
import 'demand.dart';
import 'heuristic_policy.dart';
import 'interaction_policy.dart';
import 'page_media_evidence.dart';
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
  int? _previousPlannedCurrentIndex;
  int? _currentIndex;
  int? _lastCurrentIndex;
  final BrowsingDirectionPredictor _directionPredictor =
      BrowsingDirectionPredictor();
  int _readDirection = 1;
  final Map<int, bool> _runtimeAnimatedPages = <int, bool>{};
  final Set<int> _runtimeLocalStaticPages = <int>{};
  final Set<int> _runtimeExternalStaticPages = <int>{};
  final Set<int> _runtimeWebpCostPages = <int>{};
  ReaderObs? _lastObservation;
  Set<int>? _previousVisibleIndexes;
  bool? _previousVerticalActive;
  ResourceInteractionPhase? _previousResourceInteractionPhase;

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
    final changed = webp
        ? _runtimeWebpCostPages.add(pageIndex)
        : _runtimeWebpCostPages.remove(pageIndex);
    if (!changed) return false;
    final observation = _lastObservation;
    if (observation != null) {
      _replan(observation, force: true);
    }
    return true;
  }

  bool isRuntimeExternalStaticPage(int pageIndex) =>
      pageIndex >= 0 &&
      pageIndex < chapter.pages.length &&
      _runtimeAnimatedPages[pageIndex] == false &&
      _runtimeExternalStaticPages.contains(pageIndex);

  bool classifyPage({
    required int pageIndex,
    required bool animated,
    bool? localPresentationReady,
    bool externalPresentationRequired = false,
  }) {
    if (pageIndex < 0 || pageIndex >= chapter.pages.length) return false;
    final current = _runtimeAnimatedPages[pageIndex];
    var localityChanged = false;
    var presentationChanged = false;
    if (animated) {
      localityChanged = _runtimeLocalStaticPages.remove(pageIndex);
      presentationChanged = _runtimeExternalStaticPages.remove(pageIndex);
    } else {
      presentationChanged = externalPresentationRequired
          ? _runtimeExternalStaticPages.add(pageIndex)
          : _runtimeExternalStaticPages.remove(pageIndex);
      if (localPresentationReady != null) {
        localityChanged = localPresentationReady
            ? _runtimeLocalStaticPages.add(pageIndex)
            : _runtimeLocalStaticPages.remove(pageIndex);
      }
    }
    if (current == animated && !localityChanged && !presentationChanged) {
      return false;
    }
    _runtimeAnimatedPages[pageIndex] = animated;
    final observation = _lastObservation;
    if (observation != null) {
      _replan(observation, force: true);
    }
    return true;
  }

  bool _animatedFlowActiveFor(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= chapter.pages.length) return false;
    final runtime = _runtimeAnimatedPages[pageIndex];
    if (runtime != null) return runtime;
    final page = chapter.pages[pageIndex];
    if (page.animatedHint) return true;
    // Manifest hints, `.webp` URIs and runtime sniffing all prove only the
    // encoded WebP container cost. Decoder classification remains the sole
    // static/animated authority and is checked above.
    if (hasWebpCostEvidence(
      page,
      runtimeObserved: _runtimeWebpCostPages.contains(pageIndex),
    )) {
      return true;
    }
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
        isPresentationMotionInteraction(observation.interaction);
    final verticalActiveChanged = _previousVerticalActive != verticalActive;
    final interactionPhase = resourceInteractionPhase(observation.interaction);
    final interactionPhaseChanged =
        _previousResourceInteractionPhase != interactionPhase;
    final windowChanged =
        !_sameRoles(_previousRoles, window.roles) ||
        visibleChanged ||
        verticalActiveChanged ||
        interactionPhaseChanged ||
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
      readDirection: _readDirection,
    );
    final proposal = policy.createPlan(
      revision: candidateRevision,
      chapter: chapter,
      observation: observation,
      window: window,
      decodeTarget: _decodeTarget,
      runtimeAnimatedPages: _runtimeAnimatedPages,
      runtimeLocalStaticPages: _runtimeLocalStaticPages,
      runtimeExternalStaticPages: _runtimeExternalStaticPages,
      runtimeWebpCostPages: _runtimeWebpCostPages,
      assumeUnresolvedStatic: _assumeUnresolvedStatic,
      downloadFlow: animatedFlow,
      readDirection: _readDirection,
    );
    final desiredPlan = guard.enforce(proposal);
    final bridgeLocalMovement = _lastCurrentIndex == null ||
        (observation.currentIndex - _lastCurrentIndex!).abs() <= 5;
    final bridged = _bridgeActiveVerticalDownloads(
      desiredPlan,
      verticalActive: verticalActive && bridgeLocalMovement,
      allowSpeculativeAdvance:
          _previousPlannedCurrentIndex != observation.currentIndex,
    );
    final plan = guard.enforce(bridged.plan);
    final diff = DemandDiff.between(_previous, plan);

    // Runtime source/media evidence and Reader window metadata may change
    // without changing any authoritative scheduling request. Never promote an
    // empty semantic demand diff into a scheduler revision merely because the
    // viewport metadata changed: Reader owns the continuous visual position.
    if (!_decodeTargetDirty && diff.isEmpty) {
      _previousRoles = Map<int, PageRole>.unmodifiable(window.roles);
      _previousRetainedIndex = window.retainedIndex;
      _previousVisibleIndexes = currentVisibleIndexes;
      _previousVerticalActive = verticalActive;
      _previousResourceInteractionPhase = interactionPhase;
      _previousPlannedCurrentIndex = observation.currentIndex;
      return;
    }

    _revision = candidateRevision;
    _previousRoles = Map<int, PageRole>.unmodifiable(window.roles);
    _previousRetainedIndex = window.retainedIndex;
    _previousVisibleIndexes = currentVisibleIndexes;
    _previousVerticalActive = verticalActive;
    _previousResourceInteractionPhase = interactionPhase;
    _previousPlannedCurrentIndex = observation.currentIndex;
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
          'desiredDownloads': desiredPlan.downloads.length,
          'downloadBridgeActive': bridged.active,
          'downloadBridgeLocalMovement': bridgeLocalMovement,
          'downloadBridgeRetained': bridged.retainedOutsideDesired,
          'downloadBridgeDeferredDesired': bridged.deferredDesired,
          'downloadBridgeDesiredAdvanced': bridged.desiredAdvanced,
          'downloadBridgeSchedulingRetained': bridged.schedulingRetained,
          'decodes': plan.decodes.length,
          'uploads': plan.uploads.length,
          'encodedWorkModes': <String, int>{
            for (final mode in EncodedWorkMode.values)
              mode.name: plan.downloads.values
                  .where((demand) => demand.encodedWorkMode == mode)
                  .length,
          },
          'decodeTargetZero': plan.decodes.values
              .where((demand) => demand.targetWatermark == 0)
              .length,
          'uploadPrepareDisabled': plan.uploads.values
              .where((demand) => !demand.prepareOutput)
              .length,
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
          'runtimeLocalStaticPages': _runtimeLocalStaticPages.length,
          'runtimeExternalStaticPages': _runtimeExternalStaticPages.length,
          'runtimeWebpCostPages': _runtimeWebpCostPages.length,
          'assumeUnresolvedStatic': _assumeUnresolvedStatic,
          'animatedFlowActive': animatedFlow.active,
          'animatedFlowFrameTargets': <String, int>{
            for (final entry in animatedFlow.targetFramesByIndex.entries)
              entry.key.toString(): entry.value,
          },
          'currentIndex': observation.currentIndex,
          'readDirection': _readDirection,
          'targetIndex': observation.targetCoverage?.pageIndex,
          'retainedIndex': window.retainedIndex,
          'interaction': observation.interaction.name,
          'resourceInteractionPhase': interactionPhase.name,
        },
      ),
    );
    _onUpdate(PipelineDelta(plan: plan, diff: diff, window: window));
  }

  _ActiveDownloadBridgeResult _bridgeActiveVerticalDownloads(
    DemandPlan desired, {
    required bool verticalActive,
    required bool allowSpeculativeAdvance,
  }) {
    if (!verticalActive || _previous.downloads.isEmpty) {
      return _ActiveDownloadBridgeResult(
        plan: desired,
        active: false,
        retainedOutsideDesired: 0,
        deferredDesired: 0,
        desiredAdvanced: 0,
        schedulingRetained: 0,
      );
    }

    // Reader-visible/decode/upload correctness stays authoritative and
    // immediate. Only encoded-only speculative membership is allowed to lag
    // while the viewport is moving. This avoids flipping the whole asymmetric
    // 7/3 transport window in one UI-isolate event turn when readDirection
    // reverses.
    bool immediateMediaRole(PageRole role) => switch (role) {
          PageRole.current ||
          PageRole.transition ||
          PageRole.next ||
          PageRole.next2 ||
          PageRole.previous => true,
          PageRole.last ||
          PageRole.near ||
          PageRole.far ||
          PageRole.detached => false,
        };
    // Static one-frame warming can now cover the whole encoded window. Do not
    // let those far speculative media intents turn every download into a
    // mandatory source during a direction flip; that would bypass this bridge
    // and swap the asymmetric 3/7 working set in one event turn. Current,
    // transition, real viewport pages and the established 2/1 near-media
    // envelope remain immediate. Far one-frame work follows the bridged source
    // membership and becomes eligible as that membership advances.
    final mandatory = <DownloadId>{
      for (final entry in desired.decodes.entries)
        if (immediateMediaRole(entry.value.role)) entry.key.download,
      for (final entry in desired.uploads.entries)
        if (immediateMediaRole(entry.value.role) ||
            entry.value.viewportVisible)
          entry.key.download,
      for (final entry in desired.downloads.entries)
        if (entry.value.role == PageRole.current ||
            entry.value.role == PageRole.transition)
          entry.key,
    };
    if (!mandatory.every(desired.downloads.containsKey)) {
      // A guarded plan must already carry the transport source for every
      // foreground decode/upload. If that invariant is ever violated, do not
      // hide it behind the bridge.
      return _ActiveDownloadBridgeResult(
        plan: desired,
        active: false,
        retainedOutsideDesired: 0,
        deferredDesired: 0,
        desiredAdvanced: 0,
        schedulingRetained: 0,
      );
    }

    final capacity = desired.downloads.length;
    final downloads = <DownloadId, DownloadDemand>{};

    final mandatoryEntries = mandatory
        .map((id) => MapEntry(id, desired.downloads[id]!))
        .toList(growable: false)
      ..sort((a, b) => b.value.priority.compareTo(a.value.priority));
    for (final entry in mandatoryEntries) {
      downloads[entry.key] = entry.value;
    }

    var schedulingRetained = 0;
    final shared = desired.downloads.keys
        .where(
          (id) => !mandatory.contains(id) && _previous.downloads.containsKey(id),
        )
        .toList(growable: false)
      ..sort((a, b) => desired.downloads[b]!.priority
          .compareTo(desired.downloads[a]!.priority));
    for (final id in shared) {
      if (downloads.length >= capacity) break;
      // Identity retention must not retain a stale semantic role. A previous
      // current can become desired last/near on the very next observation;
      // carrying its old role would manufacture a second current demand.
      downloads[id] = desired.downloads[id]!;
      schedulingRetained++;
    }

    final missingDesired = desired.downloads.entries
        .where((entry) => !downloads.containsKey(entry.key))
        .toList(growable: false)
      ..sort((a, b) => b.value.priority.compareTo(a.value.priority));

    // Advance at most one encoded-only speculative identity per committed page
    // movement. Mandatory near/current transport above is unlimited and always
    // immediate; this one-slot budget only spreads far 7/3 migration across
    // successive pageCurrent observations instead of one direction-flip turn.
    var desiredAdvanced = 0;
    var missingDesiredStart = 0;
    if (allowSpeculativeAdvance && missingDesired.isNotEmpty &&
        downloads.length < capacity) {
      final entry = missingDesired.first;
      downloads[entry.key] = entry.value;
      desiredAdvanced = 1;
      missingDesiredStart = 1;
    }

    var retainedOutsideDesired = 0;
    final stale = _previous.downloads.keys
        .where((id) => !desired.downloads.containsKey(id))
        .toList(growable: false)
      ..sort((a, b) => _previous.downloads[b]!.priority
          .compareTo(_previous.downloads[a]!.priority));
    for (final id in stale) {
      if (downloads.length >= capacity) break;
      downloads[id] = _refreshBridgedDownload(
        _previous.downloads[id]!,
        desiredRevision: desired.revision,
        speculativeOnly: true,
      );
      retainedOutsideDesired++;
    }

    for (var index = missingDesiredStart;
        index < missingDesired.length;
        index++) {
      if (downloads.length >= capacity) break;
      final entry = missingDesired[index];
      downloads[entry.key] = entry.value;
    }

    final deferredDesired = desired.downloads.keys
        .where((id) => !downloads.containsKey(id))
        .length;
    if (retainedOutsideDesired == 0 &&
        deferredDesired == 0 &&
        schedulingRetained == 0) {
      return _ActiveDownloadBridgeResult(
        plan: desired,
        active: false,
        retainedOutsideDesired: 0,
        deferredDesired: 0,
        desiredAdvanced: 0,
        schedulingRetained: 0,
      );
    }

    final keep = desired.keep
        .where((resource) => resource.kind != ResourceKind.download)
        .toSet();
    for (final id in downloads.keys) {
      keep.add(ResourceId.download(id));
    }

    final decodes = <DecodeId, DecodeDemand>{
      for (final entry in desired.decodes.entries)
        if (downloads.containsKey(entry.key.download)) entry.key: entry.value,
    };
    final uploads = <DecodeId, UploadDemand>{
      for (final entry in desired.uploads.entries)
        if (downloads.containsKey(entry.key.download)) entry.key: entry.value,
    };

    return _ActiveDownloadBridgeResult(
      plan: DemandPlan(
        revision: desired.revision,
        downloads: downloads,
        decodes: decodes,
        uploads: uploads,
        keep: keep,
      ),
      active: true,
      retainedOutsideDesired: retainedOutsideDesired,
      deferredDesired: deferredDesired,
      desiredAdvanced: desiredAdvanced,
      schedulingRetained: schedulingRetained,
    );
  }

  DownloadDemand _refreshBridgedDownload(
    DownloadDemand previous, {
    required int desiredRevision,
    bool speculativeOnly = false,
  }) {
    final unsafeRole = previous.role == PageRole.current ||
        previous.role == PageRole.transition ||
        previous.role == PageRole.next ||
        previous.role == PageRole.next2 ||
        previous.role == PageRole.previous;
    if (speculativeOnly && unsafeRole) {
      return DownloadDemand(
        role: PageRole.far,
        priority: previous.priority.clamp(520, 760).toInt(),
        reason: 'heuristic:active-download-bridge-retained',
        expirationRevision: desiredRevision + 1,
        flowTargetFrames: 0,
        encodedWorkMode: EncodedWorkMode.retained,
      );
    }
    return DownloadDemand(
      role: previous.role,
      priority: previous.priority,
      reason: previous.reason,
      expirationRevision: desiredRevision + 1,
      flowTargetFrames: previous.flowTargetFrames,
      encodedWorkMode: previous.encodedWorkMode,
      decisionId: previous.decisionId,
    );
  }
}

final class _ActiveDownloadBridgeResult {
  const _ActiveDownloadBridgeResult({
    required this.plan,
    required this.active,
    required this.retainedOutsideDesired,
    required this.deferredDesired,
    required this.desiredAdvanced,
    required this.schedulingRetained,
  });

  final DemandPlan plan;
  final bool active;
  final int retainedOutsideDesired;
  final int deferredDesired;
  final int desiredAdvanced;
  final int schedulingRetained;
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

bool _sameVisibleIndexes(Set<int>? previous, Set<int> next) {
  if (previous == null || previous.length != next.length) {
    return false;
  }
  return previous.containsAll(next);
}
