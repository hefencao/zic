import 'package:domain/domain.dart';

enum PageRole {
  current,
  last,
  transition,
  visible,
  next,
  next2,
  previous,
  near,
  far,
  detached,
}

final class RoleWindow {
  RoleWindow(Map<int, PageRole> roles)
      : roles = Map<int, PageRole>.unmodifiable(roles);

  final Map<int, PageRole> roles;

  PageRole roleOf(int pageIndex) => roles[pageIndex] ?? PageRole.detached;
}

final class RoleResolver {
  const RoleResolver({
    this.forwardEncodedPages = 2,
    this.backwardEncodedPages = 1,
    this.forwardDecodePages,
    this.backwardDecodePages,
    this.nearRadius = 3,
    this.transitionThreshold = 0.15,
  });

  final int forwardEncodedPages;
  final int backwardEncodedPages;
  final int? forwardDecodePages;
  final int? backwardDecodePages;
  final int nearRadius;
  final double transitionThreshold;

  RoleWindow resolve(
    ChapterManifest chapter,
    ReaderObs observation, {
    int? previousCurrentIndex,
  }) {
    final roles = <int, PageRole>{};
    final current = observation.currentIndex
        .clamp(0, chapter.pages.length - 1)
        .toInt();
    _setRole(roles, current, PageRole.current);
    if (previousCurrentIndex != null &&
        previousCurrentIndex >= 0 &&
        previousCurrentIndex < chapter.pages.length &&
        previousCurrentIndex != current) {
      _setRole(roles, previousCurrentIndex, PageRole.last);
    }

    final target = observation.targetCoverage;
    final targetIsVisible = target != null &&
        (observation.direction == ReadingDirection.vertical
            ? target.fraction > 0
            : target.fraction >= transitionThreshold);
    if (targetIsVisible &&
        target != null &&
        target.pageIndex >= 0 &&
        target.pageIndex < chapter.pages.length &&
        target.pageIndex != current) {
      _setRole(roles, target.pageIndex, PageRole.transition);
    }
    if (observation.direction == ReadingDirection.vertical) {
      for (final coverage in observation.visibleCoverages) {
        if (coverage.fraction <= 0 ||
            coverage.pageIndex == current ||
            coverage.pageIndex < 0 ||
            coverage.pageIndex >= chapter.pages.length) {
          continue;
        }
        _setRole(roles, coverage.pageIndex, PageRole.visible);
      }
    }

    var forwardSlot = 0;
    for (var offset = 1; forwardSlot < forwardEncodedPages; offset++) {
      final index = current + offset;
      if (index >= chapter.pages.length) {
        break;
      }
      if (roles[index] == PageRole.last) {
        continue;
      }
      forwardSlot++;
      _setRole(
        roles,
        index,
        forwardSlot == 1
            ? PageRole.next
            : forwardSlot == 2 &&
                    (forwardDecodePages == null ||
                        forwardSlot <= forwardDecodePages!)
                ? PageRole.next2
                : forwardDecodePages == null ||
                        forwardSlot <= forwardDecodePages!
                    ? PageRole.near
                    : PageRole.far,
      );
    }
    var backwardSlot = 0;
    for (var offset = 1; backwardSlot < backwardEncodedPages; offset++) {
      final index = current - offset;
      if (index < 0) {
        break;
      }
      if (roles[index] == PageRole.last) {
        continue;
      }
      backwardSlot++;
      _setRole(
        roles,
        index,
        backwardSlot == 1
            ? PageRole.previous
            : backwardDecodePages == null ||
                    backwardSlot <= backwardDecodePages!
                ? PageRole.near
                : PageRole.far,
      );
    }
    for (var offset = 1; offset <= nearRadius; offset++) {
      final before = current - offset;
      final after = current + offset;
      if (before >= 0) {
        _setRole(roles, before, PageRole.near);
      }
      if (after < chapter.pages.length) {
        _setRole(roles, after, PageRole.near);
      }
    }
    return RoleWindow(roles);
  }

  void _setRole(Map<int, PageRole> roles, int index, PageRole role) {
    final existing = roles[index];
    if (existing == null || _rank(role) > _rank(existing)) {
      roles[index] = role;
    }
  }

  int _rank(PageRole role) => switch (role) {
        PageRole.current => 100,
        PageRole.last => 95,
        PageRole.transition => 94,
        PageRole.visible => 92,
        PageRole.next => 70,
        PageRole.next2 => 68,
        PageRole.previous => 65,
        PageRole.near => 50,
        PageRole.far => 10,
        PageRole.detached => 0,
      };
}
