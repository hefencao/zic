import 'package:domain/domain.dart';
import 'package:pipeline/pipeline.dart';

typedef PlaybackToggle = bool Function(DecodeId id);

final class PlaybackGate {
  final Map<DecodeId, bool> _frozen = <DecodeId, bool>{};

  Map<DecodeId, bool> get states =>
      Map<DecodeId, bool>.unmodifiable(_frozen);

  void apply({
    required ViewportState viewport,
    required Map<int, DecodeId> ids,
    required PlaybackToggle freeze,
    required PlaybackToggle resume,
  }) {
    final visible = <DecodeId>{};
    final current = ids[viewport.currentPageIndex];
    if (current != null) {
      visible.add(current);
    }
    final targetIndex = viewport.targetPageIndex;
    if (targetIndex != null) {
      final target = ids[targetIndex];
      if (target != null) {
        visible.add(target);
      }
    }

    for (final id in _frozen.keys.toList(growable: false)) {
      if (visible.contains(id)) {
        continue;
      }
      if (_frozen[id] == false) {
        freeze(id);
      }
      _frozen.remove(id);
    }

    final freezeAll = viewport.freezesPresentation;
    final dominant = viewport.dominantPageIndex == null
        ? null
        : ids[viewport.dominantPageIndex!];
    for (final id in visible) {
      final shouldFreeze = freezeAll || id != dominant;
      final prior = _frozen[id];
      if (prior == shouldFreeze) {
        continue;
      }
      final changed = shouldFreeze ? freeze(id) : resume(id);
      if (changed) {
        _frozen[id] = shouldFreeze;
      }
    }
  }

  void clear({required PlaybackToggle freeze}) {
    for (final entry in _frozen.entries) {
      if (!entry.value) {
        freeze(entry.key);
      }
    }
    _frozen.clear();
  }
}
