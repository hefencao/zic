import 'package:domain/domain.dart';

enum PageRole { current, transition, next, previous, near, far, detached }

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
    this.nearRadius = 3,
    this.transitionThreshold = 0.15,
  });

  final int forwardEncodedPages;
  final int backwardEncodedPages;
  final int nearRadius;
  final double transitionThreshold;

  RoleWindow resolve(ChapterManifest chapter, ReaderObs observation) {
    final roles = <int, PageRole>{};
    final current = observation.currentIndex
        .clamp(0, chapter.pages.length - 1)
        .toInt();
    _setRole(roles, current, PageRole.current);

    final target = observation.targetCoverage;
    if (target != null &&
        target.fraction >= transitionThreshold &&
        target.pageIndex >= 0 &&
        target.pageIndex < chapter.pages.length &&
        target.pageIndex != current) {
      _setRole(roles, target.pageIndex, PageRole.transition);
    }

    for (var offset = 1; offset <= forwardEncodedPages; offset++) {
      final index = current + offset;
      if (index < chapter.pages.length) {
        _setRole(roles, index, offset == 1 ? PageRole.next : PageRole.near);
      }
    }
    for (var offset = 1; offset <= backwardEncodedPages; offset++) {
      final index = current - offset;
      if (index >= 0) {
        _setRole(
          roles,
          index,
          offset == 1 ? PageRole.previous : PageRole.near,
        );
      }
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
        PageRole.transition => 90,
        PageRole.next => 70,
        PageRole.previous => 65,
        PageRole.near => 50,
        PageRole.far => 10,
        PageRole.detached => 0,
      };
}
