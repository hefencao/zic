/// Process-local admission state for Home-owned navigation routes.
///
/// This owner only prevents duplicate route entry and exposes whether the
/// Reader route currently covers Home. It deliberately has no Flutter presentation/navigation or subsystem
/// authority; callers still own route construction, push/pop and UI refresh.
final class HomeRouteAdmission {
  final Set<String> _comicRouteIdentities = <String>{};
  bool _readerRouteOpen = false;
  bool _downloadManagerRouteOpen = false;

  bool get readerRouteOpen => _readerRouteOpen;

  bool get downloadManagerRouteOpen => _downloadManagerRouteOpen;

  bool get hasComicRoutes => _comicRouteIdentities.isNotEmpty;

  void beginReaderRoute() {
    _readerRouteOpen = true;
  }

  bool endReaderRoute() {
    if (!_readerRouteOpen) return false;
    _readerRouteOpen = false;
    return true;
  }

  bool tryBeginDownloadManagerRoute() {
    if (_downloadManagerRouteOpen) return false;
    _downloadManagerRouteOpen = true;
    return true;
  }

  bool endDownloadManagerRoute() {
    if (!_downloadManagerRouteOpen) return false;
    _downloadManagerRouteOpen = false;
    return true;
  }

  bool tryBeginComicRoute(String identity) =>
      _comicRouteIdentities.add(identity);

  bool endComicRoute(String identity) =>
      _comicRouteIdentities.remove(identity);

  bool comicRouteOpen(String identity) =>
      _comicRouteIdentities.contains(identity);
}
