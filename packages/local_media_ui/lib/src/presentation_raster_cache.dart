part of '../local_media_ui.dart';

const int pipelinePresentationRasterMaximumBytes = 100 * 1024 * 1024;
const int pipelinePresentationRasterMaximumEntries = 1000;

/// Process-wide presentation-raster authority for Reader static pages.
///
/// Flutter supplies the [ImageStreamCompleter]/raster backend, but Reader
/// residency authority lives here. This manager owns the reusable keepAlive
/// lease, exact provider key, weight/LRU metadata, admission backpressure and
/// presentation-generation invalidation. Mounted Reader static presentation
/// must not add a second Flutter Image/TickerMode keepAlive owner; no raster
/// bytes are copied.
final class PipelinePresentationRasterCache
    implements
        PresentationRasterCacheMaintenance,
        PipelinePresentationCacheAuthority {
  PipelinePresentationRasterCache({
    this.maximumBytes = pipelinePresentationRasterMaximumBytes,
    this.maximumEntries = pipelinePresentationRasterMaximumEntries,
    ImageCache? imageCache,
  }) : assert(maximumBytes > 0),
       assert(maximumEntries > 0),
       _imageCacheOverride = imageCache;

  final int maximumBytes;
  final int maximumEntries;
  final ImageCache? _imageCacheOverride;
  ImageCache? _resolvedImageCache;

  ImageCache get _imageCache =>
      _imageCacheOverride ??
      (_resolvedImageCache ??= PaintingBinding.instance.imageCache);

  ImageCache? get _existingImageCache =>
      _imageCacheOverride ?? _resolvedImageCache;
  final LinkedHashMap<PresentationRasterCacheKey, _PresentationRasterEntry>
  _entries =
      LinkedHashMap<PresentationRasterCacheKey, _PresentationRasterEntry>();
  final Map<Object, PresentationRasterCacheKey> _keysByIdentity =
      <Object, PresentationRasterCacheKey>{};
  final Map<Object, PipelinePresentationCacheClaim> _claimsByIdentity =
      <Object, PipelinePresentationCacheClaim>{};
  final Set<Object> _speculativeAdmissionDenied = <Object>{};
  final Set<PipelinePresentationCacheInvalidationListener> _listeners =
      <PipelinePresentationCacheInvalidationListener>{};
  final Set<Object> _pendingBudgetInvalidations = <Object>{};
  final Set<Object> _pendingGenericProviderEvictions = <Object>{};
  final List<_PresentationRasterEntry> _pendingPhysicalEvictions =
      <_PresentationRasterEntry>[];
  bool _maintenanceScheduled = false;
  bool _globalBudgetSyncPending = false;
  int _maintenanceEpoch = 0;
  int _bytes = 0;

  ImageProvider<Object> providerFor({
    required ImageProvider<Object> provider,
    required Object presentationIdentity,
  }) => _ManagedPresentationImageProvider(
    owner: this,
    provider: provider,
    presentationIdentity: presentationIdentity,
  );

  ImageProvider<Object>? residentProviderForIdentity(
    Object presentationIdentity,
  ) {
    final key = _keysByIdentity[presentationIdentity];
    if (key == null) return null;
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry;
    return _ResidentPresentationImageProvider(
      key: key,
      completer: entry.completer,
    );
  }

  @override
  void addInvalidationListener(
    PipelinePresentationCacheInvalidationListener listener,
  ) {
    _listeners.add(listener);
  }

  @override
  void removeInvalidationListener(
    PipelinePresentationCacheInvalidationListener listener,
  ) {
    _listeners.remove(listener);
  }

  @override
  void updatePresentationClaim(
    Object presentationIdentity,
    PipelinePresentationCacheClaim claim,
  ) {
    final previous = _claimsByIdentity[presentationIdentity];
    if (previous == claim) return;
    _claimsByIdentity[presentationIdentity] = claim;
    if (claim != PipelinePresentationCacheClaim.speculative) {
      _speculativeAdmissionDenied.remove(presentationIdentity);
      // Budget trim withdraws speculative authority before its idle physical
      // cleanup. A role promotion can arrive in that gap; reclaim the still-live
      // managed keepAlive instead of completing a stale far-page eviction and
      // immediately forcing the new deadline page to rebuild the same raster.
      final reclaimed = _takePendingBudgetEviction(presentationIdentity);
      if (reclaimed != null) {
        reclaimed.claim = claim;
        _entries[reclaimed.key] = reclaimed;
        _keysByIdentity[presentationIdentity] = reclaimed.key;
        _bytes += reclaimed.sizeBytes;
        _scheduleMaintenance(syncGlobalBudget: true);
      }
    }
    final key = _keysByIdentity[presentationIdentity];
    final entry = key == null ? null : _entries.remove(key);
    if (entry != null) {
      entry.claim = claim;
      _entries[key!] = entry;
    }
    _trimToBudget();
  }

  _PresentationRasterEntry? _takePendingBudgetEviction(
    Object presentationIdentity,
  ) {
    for (var index = 0; index < _pendingPhysicalEvictions.length; index++) {
      final entry = _pendingPhysicalEvictions[index];
      if (!identical(entry.key.presentationIdentity, presentationIdentity)) {
        continue;
      }
      _pendingPhysicalEvictions.removeAt(index);
      _pendingBudgetInvalidations.remove(presentationIdentity);
      return entry;
    }
    return null;
  }

  @override
  void releasePresentationClaim(Object presentationIdentity) {
    if (_claimsByIdentity.remove(presentationIdentity) == null) return;
    final key = _keysByIdentity[presentationIdentity];
    final entry = key == null ? null : _entries[key];
    if (entry != null) {
      entry.claim = PipelinePresentationCacheClaim.speculative;
    }
    _trimToBudget();
  }

  @override
  bool allowsPresentationWarm(Object presentationIdentity) {
    if (!_speculativeAdmissionDenied.contains(presentationIdentity)) {
      return true;
    }
    final claim = _claimsByIdentity[presentationIdentity];
    return claim == PipelinePresentationCacheClaim.deadline ||
        claim == PipelinePresentationCacheClaim.protected;
  }

  @override
  void invalidatePresentationIdentity(Object presentationIdentity) {
    _claimsByIdentity.remove(presentationIdentity);
    _speculativeAdmissionDenied.remove(presentationIdentity);
    final key = _keysByIdentity[presentationIdentity];
    if (key == null) return;
    _evict(key, notify: true);
  }

  void _resolveStreamForKey({
    required ImageConfiguration configuration,
    required ImageStream stream,
    required PresentationRasterCacheKey key,
    required ImageProvider<Object> provider,
    required ImageErrorListener handleError,
  }) {
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing;
      stream.setCompleter(existing.completer);
      return;
    }

    final previous = _keysByIdentity[key.presentationIdentity];
    if (previous != null && previous != key) {
      _evict(previous, notify: false);
    }

    final inner = provider.resolve(configuration);
    final immediate = inner.completer;
    if (immediate != null) {
      _admit(key: key, completer: immediate, providerKey: key.providerKey);
      stream.setCompleter(immediate);
      return;
    }

    late final ImageStreamListener bootstrap;
    bootstrap = ImageStreamListener(
      (info, _) {
        info.dispose();
        inner.removeListener(bootstrap);
        final completer = inner.completer;
        if (completer == null) {
          handleError(
            StateError(
              'presentation raster stream completed without completer',
            ),
            StackTrace.current,
          );
          return;
        }
        _admit(key: key, completer: completer, providerKey: key.providerKey);
        if (stream.completer == null) {
          stream.setCompleter(completer);
        }
      },
      onError: (Object error, StackTrace? stackTrace) {
        inner.removeListener(bootstrap);
        handleError(error, stackTrace);
      },
    );
    inner.addListener(bootstrap);
  }

  void _admit({
    required PresentationRasterCacheKey key,
    required ImageStreamCompleter completer,
    required Object providerKey,
  }) {
    final existing = _entries[key];
    if (existing != null) {
      _entries.remove(key);
      _entries[key] = existing;
      return;
    }
    final handle = completer.keepAlive();
    final entry = _PresentationRasterEntry(
      key: key,
      providerKey: providerKey,
      completer: completer,
      handle: handle,
      claim:
          _claimsByIdentity[key.presentationIdentity] ??
          PipelinePresentationCacheClaim.speculative,
    );
    _entries[key] = entry;
    _keysByIdentity[key.presentationIdentity] = key;

    late final ImageStreamListener firstFrame;
    firstFrame = ImageStreamListener(
      (info, _) {
        final sizeBytes = info.sizeBytes;
        info.dispose();
        completer.removeListener(firstFrame);
        final current = _entries[key];
        if (!identical(current, entry)) return;
        _bytes -= entry.sizeBytes;
        entry.sizeBytes = sizeBytes;
        _bytes += sizeBytes;
        // From this point the managed keepAlive handle is the sole reusable
        // residency owner for this Reader raster. Remove the generic Flutter
        // ImageCache keepAlive entry so the same raster is not governed by two
        // unrelated LRUs; mounted listeners remain live and the handle keeps
        // the completer/raster resident until this authority evicts it.
        _trimToBudget();
        _pendingGenericProviderEvictions.add(entry.providerKey);
        _scheduleMaintenance(syncGlobalBudget: true);
      },
      onError: (Object error, StackTrace? stackTrace) {
        completer.removeListener(firstFrame);
        if (identical(_entries[key], entry)) {
          // Decode failure is not an ordinary residency revocation. The
          // mounted/detached consumer still owns the error channel and, for a
          // mounted presentation, the exact encoded-read authority needed to
          // decide whether recovery may mutate durable state. Retire only the
          // failed cache entry here; notifying Pipeline first would synchronously
          // unmount that consumer and swallow the authoritative error.
          _evict(key, notify: false);
        }
      },
    );
    completer.addListener(firstFrame);
  }

  void _syncGlobalImageCacheBudget() {
    // The process-level cache authority may exist before Flutter bindings are
    // initialized. Merely inspecting/clearing an empty presentation plane must
    // therefore stay renderer-free. Once a raster has actually resolved, the
    // backend is known and can share the remaining process presentation budget.
    final imageCache = _existingImageCache;
    if (imageCache == null) return;
    final remainingBytes = math.max(0, maximumBytes - _bytes);
    final remainingEntries = math.max(0, maximumEntries - _entries.length);
    if (imageCache.maximumSizeBytes != remainingBytes) {
      imageCache.maximumSizeBytes = remainingBytes;
    }
    if (imageCache.maximumSize != remainingEntries) {
      imageCache.maximumSize = remainingEntries;
    }
  }

  void _trimToBudget() {
    while ((_bytes > maximumBytes || _entries.length > maximumEntries) &&
        _entries.isNotEmpty) {
      PresentationRasterCacheKey? victim;
      for (final entry in _entries.entries) {
        // The presentation authority owns liveness explicitly. Only
        // speculative/unclaimed entries are reusable cache slack; deadline and
        // protected entries remain pinned even if Flutter's unrelated global
        // ImageCache has already dropped its own keepAlive key.
        if (entry.value.claim == PipelinePresentationCacheClaim.speculative) {
          victim = entry.key;
          break;
        }
      }
      if (victim == null) break;
      _evict(
        victim,
        notify: true,
        denySpeculativeRewarm: true,
        deferBudgetInvalidation: true,
      );
    }
  }

  void _evict(
    PresentationRasterCacheKey key, {
    required bool notify,
    bool denySpeculativeRewarm = false,
    bool deferBudgetInvalidation = false,
  }) {
    final entry = _entries.remove(key);
    if (entry == null) return;
    if (_keysByIdentity[key.presentationIdentity] == key) {
      _keysByIdentity.remove(key.presentationIdentity);
    }
    if (denySpeculativeRewarm) {
      _speculativeAdmissionDenied.add(key.presentationIdentity);
    }
    _bytes -= entry.sizeBytes;
    if (deferBudgetInvalidation) {
      _pendingPhysicalEvictions.add(entry);
      _scheduleMaintenance();
    } else {
      _scheduleFrameDeferredPhysicalEviction(entry);
    }
    if (notify) {
      if (deferBudgetInvalidation) {
        _pendingBudgetInvalidations.add(key.presentationIdentity);
      } else {
        _notifyInvalidation(key.presentationIdentity);
      }
    }
    _scheduleMaintenance(syncGlobalBudget: true);
  }

  void _scheduleFrameDeferredPhysicalEviction(_PresentationRasterEntry entry) {
    void cleanup() {
      entry.handle.dispose();
      final providerReowned = _entries.values.any(
        (current) => current.providerKey == entry.providerKey,
      );
      if (!providerReowned) {
        _imageCache.evict(entry.providerKey, includeLive: false);
      }
    }

    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.idle ||
        binding.hasScheduledFrame) {
      binding.addPostFrameCallback((_) => cleanup());
      return;
    }
    Timer.run(cleanup);
  }

  void _notifyInvalidation(Object presentationIdentity) {
    final listeners = _listeners.toList(growable: false);
    for (final listener in listeners) {
      listener(presentationIdentity);
    }
  }

  void _scheduleMaintenance({bool syncGlobalBudget = false}) {
    if (syncGlobalBudget) _globalBudgetSyncPending = true;
    if (_maintenanceScheduled) return;
    _maintenanceScheduled = true;
    final epoch = _maintenanceEpoch;

    void flush() {
      developer.Timeline.startSync('zic-presentation-raster-maintenance');
      try {
        if (epoch != _maintenanceEpoch) return;
        _maintenanceScheduled = false;
        final physicalEvictions = List<_PresentationRasterEntry>.of(
          _pendingPhysicalEvictions,
        );
        _pendingPhysicalEvictions.clear();
        for (final entry in physicalEvictions) {
          entry.handle.dispose();
          final providerReowned = _entries.values.any(
            (current) => current.providerKey == entry.providerKey,
          );
          if (!providerReowned) {
            _imageCache.evict(entry.providerKey, includeLive: false);
          }
        }

        final providerEvictions = _pendingGenericProviderEvictions.toList(
          growable: false,
        );
        _pendingGenericProviderEvictions.clear();
        for (final providerKey in providerEvictions) {
          _imageCache.evict(providerKey, includeLive: false);
        }

        if (_globalBudgetSyncPending) {
          _globalBudgetSyncPending = false;
          _syncGlobalImageCacheBudget();
        }

        final invalidations = _pendingBudgetInvalidations.toList(
          growable: false,
        );
        _pendingBudgetInvalidations.clear();
        for (final identity in invalidations) {
          _notifyInvalidation(identity);
        }

        if (_pendingPhysicalEvictions.isNotEmpty ||
            _pendingGenericProviderEvictions.isNotEmpty ||
            _pendingBudgetInvalidations.isNotEmpty ||
            _globalBudgetSyncPending) {
          _scheduleMaintenance();
        }
      } finally {
        developer.Timeline.finishSync();
      }
    }

    unawaited(
      SchedulerBinding.instance.scheduleTask<void>(
        flush,
        Priority.idle,
        debugLabel: 'zic-presentation-raster-maintenance',
      ),
    );
  }

  @override
  PresentationRasterCacheUsage inspectPresentationRasters() =>
      PresentationRasterCacheUsage(bytes: _bytes, entries: _entries.length);

  @override
  PresentationRasterCacheReport trimPresentationRasters() {
    final beforeBytes = _bytes;
    final beforeEntries = _entries.length;
    _trimToBudget();
    return PresentationRasterCacheReport(
      beforeBytes: beforeBytes,
      releasedBytes: beforeBytes - _bytes,
      remainingBytes: _bytes,
      evictedEntries: beforeEntries - _entries.length,
    );
  }

  @override
  PresentationRasterCacheReport clearPresentationRasters() {
    final beforeBytes = _bytes;
    final beforeEntries = _entries.length;
    final identities = <Object>{
      ..._pendingBudgetInvalidations,
      ..._entries.keys.map((key) => key.presentationIdentity),
    };
    _maintenanceEpoch++;
    _maintenanceScheduled = false;
    _globalBudgetSyncPending = false;
    for (final entry in _pendingPhysicalEvictions) {
      entry.handle.dispose();
      _imageCache.evict(entry.providerKey, includeLive: false);
    }
    _pendingPhysicalEvictions.clear();
    for (final providerKey in _pendingGenericProviderEvictions) {
      _imageCache.evict(providerKey, includeLive: false);
    }
    _pendingGenericProviderEvictions.clear();
    _pendingBudgetInvalidations.clear();
    for (final entry in _entries.values) {
      if (entry.claim == PipelinePresentationCacheClaim.speculative) {
        _speculativeAdmissionDenied.add(entry.key.presentationIdentity);
      }
      entry.handle.dispose();
      _imageCache.evict(entry.providerKey, includeLive: false);
    }
    _entries.clear();
    _keysByIdentity.clear();
    // A residency clear is not a demand-generation boundary. Preserve claims
    // so current/deadline pages can legally refill, while speculative entries
    // stay denied until their claim is promoted or the generation rotates.
    _bytes = 0;
    _syncGlobalImageCacheBudget();
    final listeners = _listeners.toList(growable: false);
    for (final identity in identities) {
      for (final listener in listeners) {
        listener(identity);
      }
    }
    return PresentationRasterCacheReport(
      beforeBytes: beforeBytes,
      releasedBytes: beforeBytes,
      remainingBytes: 0,
      evictedEntries: beforeEntries,
    );
  }
}

final class _PresentationRasterEntry {
  _PresentationRasterEntry({
    required this.key,
    required this.providerKey,
    required this.completer,
    required this.handle,
    required this.claim,
  });

  final PresentationRasterCacheKey key;
  final Object providerKey;
  final ImageStreamCompleter completer;
  final ImageStreamCompleterHandle handle;
  PipelinePresentationCacheClaim claim;
  int sizeBytes = 0;
}

final class _ManagedPresentationImageProvider
    extends ImageProvider<PresentationRasterCacheKey> {
  const _ManagedPresentationImageProvider({
    required this.owner,
    required this.provider,
    required this.presentationIdentity,
  });

  final PipelinePresentationRasterCache owner;
  final ImageProvider<Object> provider;
  final Object presentationIdentity;

  @override
  Future<PresentationRasterCacheKey> obtainKey(
    ImageConfiguration configuration,
  ) => provider
      .obtainKey(configuration)
      .then(
        (providerKey) => PresentationRasterCacheKey(
          presentationIdentity: presentationIdentity,
          providerKey: providerKey,
        ),
      );

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    PresentationRasterCacheKey key,
    ImageErrorListener handleError,
  ) {
    owner._resolveStreamForKey(
      configuration: configuration,
      stream: stream,
      key: key,
      provider: provider,
      handleError: handleError,
    );
  }
}

final class _ResidentPresentationImageProvider
    extends ImageProvider<PresentationRasterCacheKey> {
  const _ResidentPresentationImageProvider({
    required this.key,
    required this.completer,
  });

  final PresentationRasterCacheKey key;
  final ImageStreamCompleter completer;

  @override
  Future<PresentationRasterCacheKey> obtainKey(
    ImageConfiguration configuration,
  ) => Future<PresentationRasterCacheKey>.value(key);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    PresentationRasterCacheKey key,
    ImageErrorListener handleError,
  ) {
    stream.setCompleter(completer);
  }
}

/// Presentation-facing capability over the single process raster-cache owner.
///
/// Widgets consume this adapter rather than branching on cache/provider
/// implementation details. It owns the two composition decisions that must stay
/// identical for detached prewarm and mounted presentation: exact resident
/// handoff, and viewport resize + managed-cache wrapping.
///
/// This is not a second cache or scheduler. All residency/LRU/keepAlive state
/// continues to live in [PipelinePresentationRasterCache].
final class _PipelinePresentationRasterAdapter {
  const _PipelinePresentationRasterAdapter(this._cache);

  final PipelinePresentationRasterCache _cache;

  ImageProvider<Object>? residentProvider(Object presentationIdentity) =>
      _cache.residentProviderForIdentity(presentationIdentity);

  PresentationRasterCacheUsage inspect() => _cache.inspectPresentationRasters();

  ImageProvider<Object> providerForViewport({
    required ImageProvider<Object> image,
    required int? sourceWidth,
    required int? sourceHeight,
    required int? maxPhysicalWidth,
    required int? maxPhysicalHeight,
    required PipelineExternalPresentationFit fit,
    Object? presentationIdentity,
  }) {
    // A resident handoff already names the exact managed raster admitted by
    // the cache owner. Re-resizing or re-wrapping it would manufacture a nested
    // key and silently create a second residency interpretation.
    if (image is _ResidentPresentationImageProvider) {
      return image;
    }

    var provider = image;
    if (sourceWidth != null &&
        sourceHeight != null &&
        maxPhysicalWidth != null &&
        maxPhysicalHeight != null &&
        sourceWidth > 0 &&
        sourceHeight > 0 &&
        maxPhysicalWidth > 0 &&
        maxPhysicalHeight > 0) {
      provider = _mediaRasterProviderForPresentation(
        image: provider,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        maxPhysicalWidth: maxPhysicalWidth,
        maxPhysicalHeight: maxPhysicalHeight,
        fit: fit,
      );
    }

    if (presentationIdentity != null) {
      provider = _cache.providerFor(
        provider: provider,
        presentationIdentity: presentationIdentity,
      );
    }
    return provider;
  }
}

/// One process-wide cache authority shared by mounted Reader pages, detached
/// Pipeline prewarm, settings maintenance and memory-pressure handling.
final pipelinePresentationRasterCache = PipelinePresentationRasterCache();

final _pipelinePresentationRasterAdapter =
    _PipelinePresentationRasterAdapter(pipelinePresentationRasterCache);
