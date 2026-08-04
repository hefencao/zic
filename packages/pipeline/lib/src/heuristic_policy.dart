import 'package:domain/domain.dart';

import 'decode_target.dart';
import 'demand.dart';
import 'role_window.dart';

final class HeuristicPolicy {
  const HeuristicPolicy({this.decodeWarmPages = false});

  final bool decodeWarmPages;

  DemandPlan createPlan({
    required int revision,
    required ChapterManifest chapter,
    required ReaderObs observation,
    required RoleWindow window,
    required DecodeTarget decodeTarget,
  }) {
    final downloads = <DownloadId, DownloadDemand>{};
    final decodes = <DecodeId, DecodeDemand>{};
    final uploads = <DecodeId, UploadDemand>{};
    final keep = <ResourceId>{};

    for (final entry in window.roles.entries) {
      final page = chapter.pages[entry.key];
      final role = entry.value;
      final content = ContentId(
        sourceId: chapter.sourceId,
        comicId: chapter.comicId,
        chapterId: chapter.chapter.chapterId,
        pageId: page.pageId,
      );
      final download = DownloadId(
        content: content,
        sourceRevision: chapter.chapter.sourceRevision,
        canonicalUri: page.uri,
      );
      final decode = DecodeId(
        download: download,
        physicalWidth: decodeTarget.physicalWidth,
        physicalHeight: decodeTarget.physicalHeight,
        pixelFormat: decodeTarget.pixelFormat,
        renderer: decodeTarget.renderer,
      );

      final downloadPriority = _downloadPriority(role);
      if (downloadPriority > 0) {
        downloads[download] = DownloadDemand(
          role: role,
          priority: downloadPriority,
          reason: 'heuristic:${role.name}',
          expirationRevision: revision + 1,
        );
        keep.add(ResourceId.download(download));
      }

      final decodeWatermark = _decodeWatermark(role);
      if (decodeWatermark > 0) {
        decodes[decode] = DecodeDemand(
          role: role,
          priority: _decodePriority(role),
          targetWatermark: decodeWatermark,
          reason: 'heuristic:${role.name}',
          expirationRevision: revision + 1,
        );
        keep.add(ResourceId.decode(decode));
      }

      if (role == PageRole.current ||
          role == PageRole.transition ||
          role == PageRole.last) {
        uploads[decode] = UploadDemand(
          role: role,
          priority: switch (role) {
            PageRole.current => 1000,
            PageRole.transition => 900,
            PageRole.last => 850,
            _ => 0,
          },
          reason: 'heuristic:${role.name}',
          expirationRevision: revision + 1,
        );
      }
    }

    return DemandPlan(
      revision: revision,
      downloads: downloads,
      decodes: decodes,
      uploads: uploads,
      keep: keep,
    );
  }

  int _downloadPriority(PageRole role) => switch (role) {
        PageRole.current => 1000,
        PageRole.last => 0,
        PageRole.transition => 900,
        PageRole.next => 720,
        PageRole.next2 => 700,
        PageRole.previous => 680,
        PageRole.near => 520,
        PageRole.far => 400,
        PageRole.detached => 0,
      };

  int _decodePriority(PageRole role) => switch (role) {
        PageRole.current => 1000,
        PageRole.transition => 900,
        PageRole.next => decodeWarmPages ? 720 : 0,
        PageRole.next2 => decodeWarmPages ? 700 : 0,
        PageRole.previous => decodeWarmPages ? 680 : 0,
        PageRole.last || PageRole.near || PageRole.far || PageRole.detached => 0,
      };

  int _decodeWatermark(PageRole role) => switch (role) {
        PageRole.current => 8,
        PageRole.transition => 2,
        PageRole.next => decodeWarmPages ? 6 : 0,
        PageRole.next2 => decodeWarmPages ? 4 : 0,
        PageRole.previous => decodeWarmPages ? 3 : 0,
        PageRole.last || PageRole.near || PageRole.far || PageRole.detached => 0,
      };
}
