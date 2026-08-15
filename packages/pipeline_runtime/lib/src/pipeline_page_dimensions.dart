part of 'pipeline_reader_session.dart';

enum PipelinePageDimensionBasis { sourceCanvas, decodedRaster }

final class PipelinePageDimensions {
  const PipelinePageDimensions({
    required this.pageIndex,
    required this.assetKey,
    required this.width,
    required this.height,
    required this.basis,
  });

  final int pageIndex;
  final String assetKey;
  final int width;
  final int height;
  final PipelinePageDimensionBasis basis;

  bool get isSourceCanvas => basis == PipelinePageDimensionBasis.sourceCanvas;
}

typedef PipelinePageDimensionsListener = void Function(
  PipelinePageDimensions dimensions,
);

/// Read-only decode-time dimension projection for one retained Reader session.
///
/// The Pipeline owns retained dimension facts. Consumers can observe them and
/// receive the current retained snapshot on attach, but cannot publish or
/// clear facts. This deliberately avoids exposing Flutter notifier types
/// across the Pipeline/Reader boundary.
abstract interface class PipelinePageDimensionsFeed {
  void addListener(
    PipelinePageDimensionsListener listener, {
    bool replay = true,
  });

  void removeListener(PipelinePageDimensionsListener listener);
}

final class _PipelinePageDimensionsPublisher
    implements PipelinePageDimensionsFeed {
  Map<String, PipelinePageDimensions> _snapshot =
      const <String, PipelinePageDimensions>{};
  final Set<PipelinePageDimensionsListener> _listeners =
      <PipelinePageDimensionsListener>{};
  bool _disposed = false;

  @override
  void addListener(
    PipelinePageDimensionsListener listener, {
    bool replay = true,
  }) {
    _requireOpen();
    if (!_listeners.add(listener) || !replay || _snapshot.isEmpty) return;
    final retained = _snapshot.values.toList(growable: false)
      ..sort((left, right) => left.pageIndex.compareTo(right.pageIndex));
    for (final dimensions in retained) {
      listener(dimensions);
    }
  }

  @override
  void removeListener(PipelinePageDimensionsListener listener) {
    _listeners.remove(listener);
  }

  bool publish(PipelinePageDimensions dimensions) {
    _requireOpen();
    final prior = _snapshot[dimensions.assetKey];
    if (prior != null &&
        prior.basis == PipelinePageDimensionBasis.sourceCanvas &&
        dimensions.basis == PipelinePageDimensionBasis.decodedRaster) {
      return false;
    }
    if (prior != null &&
        prior.pageIndex == dimensions.pageIndex &&
        prior.width == dimensions.width &&
        prior.height == dimensions.height &&
        prior.basis == dimensions.basis) {
      return false;
    }
    _snapshot = Map<String, PipelinePageDimensions>.unmodifiable(
      <String, PipelinePageDimensions>{
        ..._snapshot,
        dimensions.assetKey: dimensions,
      },
    );
    for (final listener in _listeners.toList(growable: false)) {
      listener(dimensions);
    }
    return true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    _snapshot = const <String, PipelinePageDimensions>{};
  }

  void _requireOpen() {
    if (_disposed) {
      throw StateError('Pipeline page dimensions feed is disposed');
    }
  }
}
