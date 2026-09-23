import 'package:flutter_test/flutter_test.dart';
import 'package:zic/home_route_admission.dart';

void main() {
  test('comic route admission is identity-local and join-free', () {
    final admission = HomeRouteAdmission();

    expect(admission.tryBeginComicRoute('source:a'), isTrue);
    expect(admission.tryBeginComicRoute('source:a'), isFalse);
    expect(admission.tryBeginComicRoute('source:b'), isTrue);
    expect(admission.comicRouteOpen('source:a'), isTrue);
    expect(admission.hasComicRoutes, isTrue);

    expect(admission.endComicRoute('source:a'), isTrue);
    expect(admission.tryBeginComicRoute('source:a'), isTrue);
    expect(admission.endComicRoute('missing'), isFalse);
  });

  test('download manager route has one process-local admission slot', () {
    final admission = HomeRouteAdmission();

    expect(admission.tryBeginDownloadManagerRoute(), isTrue);
    expect(admission.downloadManagerRouteOpen, isTrue);
    expect(admission.tryBeginDownloadManagerRoute(), isFalse);
    expect(admission.endDownloadManagerRoute(), isTrue);
    expect(admission.endDownloadManagerRoute(), isFalse);
    expect(admission.tryBeginDownloadManagerRoute(), isTrue);
  });

  test('reader coverage state is independent from other route locks', () {
    final admission = HomeRouteAdmission();

    admission.beginReaderRoute();
    expect(admission.readerRouteOpen, isTrue);
    expect(admission.tryBeginComicRoute('source:a'), isTrue);
    expect(admission.tryBeginDownloadManagerRoute(), isTrue);

    expect(admission.endReaderRoute(), isTrue);
    expect(admission.readerRouteOpen, isFalse);
    expect(admission.comicRouteOpen('source:a'), isTrue);
    expect(admission.downloadManagerRouteOpen, isTrue);
    expect(admission.endReaderRoute(), isFalse);
  });
}
