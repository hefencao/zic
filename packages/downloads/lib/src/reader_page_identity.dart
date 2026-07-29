import 'package:domain/domain.dart';
import 'package:telemetry/telemetry.dart';

DownloadId readerPageDownloadId(
  ChapterManifest chapter,
  PageAsset asset,
) {
  if (asset.chapterId != chapter.chapter.chapterId) {
    throw ArgumentError.value(
      asset.chapterId,
      'asset.chapterId',
      'must match ${chapter.chapter.chapterId}',
    );
  }
  return DownloadId(
    content: ContentId(
      sourceId: chapter.sourceId,
      comicId: chapter.comicId,
      chapterId: asset.chapterId,
      pageId: asset.pageId,
    ),
    sourceRevision: chapter.chapter.sourceRevision,
    canonicalUri: asset.uri,
  );
}

ReaderTraceIdentity readerPageTraceIdentity(
  ChapterManifest chapter,
  PageAsset asset,
) {
  final download = readerPageDownloadId(chapter, asset);
  return ReaderTraceIdentity(
    pageAssetKey: asset.assetKey,
    resourceKeyPrefix: download.key,
  );
}
