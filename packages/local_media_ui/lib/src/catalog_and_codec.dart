part of '../local_media_ui.dart';

LocalImageFormat? _fallbackFormatFromPipelinePrefix(Uint8List prefix) {
  final detected = detectLocalImageFormat(prefix);
  return detected == LocalImageFormat.webp ? null : detected;
}

final class WebpCatalogScreen extends StatelessWidget {
  const WebpCatalogScreen({
    this.entriesLoader = loadWebpDemoEntries,
    super.key,
  });

  final Future<List<WebpDemoEntry>> Function() entriesLoader;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: webpCatalogScreenKey,
      appBar: AppBar(title: const Text('内置动图 WebP')),
      body: FutureBuilder<List<WebpDemoEntry>>(
        future: entriesLoader(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('加载动图清单失败：${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: snapshot.requireData.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final entry = snapshot.requireData[index];
              return Card(
                key: webpCatalogEntryKey(entry.id),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: SizedBox.square(
                    dimension: 64,
                    child: Image.asset(
                      entry.asset,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                  title: Text(entry.title),
                  subtitle: Text(
                    '${entry.description}\n'
                    '${entry.frameCount} 帧 · '
                    '${entry.loopCount == 0 ? '无限循环' : '${entry.loopCount} 次播放'} · '
                    '${entry.byteLength} B',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => WebpPlayerScreen.asset(entry: entry),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// One decoded frame owned by the controlled Flutter animation renderer.
final class FlutterAnimatedFrame {
  const FlutterAnimatedFrame({
    required this.image,
    required this.duration,
  });

  final ui.Image image;
  final Duration duration;
}

/// Minimal codec contract used by the controlled animation state machine.
///
/// Keeping the state machine behind this adapter makes lifecycle, pacing and
/// presentation tests deterministic without replacing the production codec.
abstract interface class FlutterAnimatedCodec {
  int get frameCount;

  int get repetitionCount;

  Future<FlutterAnimatedFrame> getNextFrame();

  void dispose();
}

typedef FlutterAnimatedCodecFactory = Future<FlutterAnimatedCodec> Function(
  Uint8List bytes, {
  int? targetWidth,
  int? targetHeight,
});

Future<FlutterAnimatedCodec> instantiateFlutterAnimatedCodec(
  Uint8List bytes, {
  int? targetWidth,
  int? targetHeight,
}) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: targetWidth,
    targetHeight: targetHeight,
    allowUpscaling: false,
  );
  return _UiFlutterAnimatedCodec(codec);
}

final class _UiFlutterAnimatedCodec implements FlutterAnimatedCodec {
  const _UiFlutterAnimatedCodec(this._codec);

  final ui.Codec _codec;

  @override
  int get frameCount => _codec.frameCount;

  @override
  int get repetitionCount => _codec.repetitionCount;

  @override
  Future<FlutterAnimatedFrame> getNextFrame() async {
    final frame = await _codec.getNextFrame();
    return FlutterAnimatedFrame(
      image: frame.image,
      duration: frame.duration,
    );
  }

  @override
  void dispose() => _codec.dispose();
}

/// Returns the renderer-owned provider for a directly addressable local image.
///
/// This route deliberately does not call [PickedImage.readAsBytes]. It keeps the
/// encoded file outside the Dart heap and lets Flutter own the single image
/// stream used for decoding and presentation. Android content URIs and other
/// non-file sources return null and continue through the controlled byte path.
ImageProvider<Object>? localImageDirectFileProvider(PickedImage image) {
  final path = localImageFilePath(image.sourceId);
  if (path == null) {
    return null;
  }
  return encodedResourceImageProvider(
    FileEncodedResourceSource(
      path: path,
      lengthInBytes: image.byteLength,
    ),
  );
}

ImportedChapterRecord imageFolderChapterRecord(
  PickedImageFolder folder, {
  ReadingDirection readingDirection = ReadingDirection.ltr,
  DateTime? importedAt,
}) {
  final explicitCoverIndex = folder.files.indexWhere(_isExplicitFolderCover);
  final cover = explicitCoverIndex < 0
      ? folder.files.first
      : folder.files[explicitCoverIndex];
  final pageFiles = explicitCoverIndex >= 0 && folder.files.length > 1
      ? <PickedImage>[
          for (var index = 0; index < folder.files.length; index++)
            if (index != explicitCoverIndex) folder.files[index],
        ]
      : folder.files;
  return ImportedChapterRecord.folder(
    directoryId: folder.directoryPath,
    displayName: folder.displayName,
    coverSourceId: cover.sourceId,
    coverMediaFormat: cover.format.name,
    coverAnimatedHint:
        cover.format == LocalImageFormat.gif ||
        cover.format == LocalImageFormat.webp,
    readingDirection: readingDirection,
    importedAt: importedAt,
    pages: pageFiles
        .map(
          (image) => ImportedPageRecord(
            displayName: image.displayName,
            sourceId: image.sourceId,
            contentKindHint: _contentKindHint(image.format),
            mediaFormat: image.format.name,
            byteLength: image.byteLength,
            // GIF is intrinsically animated. WebP is an unresolved animation
            // candidate until the decoder reports authoritative container
            // metadata; treating it as static here can suppress frame-zero
            // bootstrap before runtime classification has a chance to run.
            animatedHint: image.format == LocalImageFormat.gif ||
                image.format == LocalImageFormat.webp,
          ),
        )
        .toList(growable: false),
  );
}

bool _isExplicitFolderCover(PickedImage image) {
  final normalized = image.displayName.trim().replaceAll('\\', '/');
  if (normalized.isEmpty || normalized.contains('/')) {
    return false;
  }
  final dot = normalized.lastIndexOf('.');
  final stem = dot <= 0 ? normalized : normalized.substring(0, dot);
  return stem.toLowerCase() == 'cover';
}

ContentKindHint _contentKindHint(LocalImageFormat format) => switch (format) {
      LocalImageFormat.jpeg => ContentKindHint.jpeg,
      LocalImageFormat.png => ContentKindHint.png,
      LocalImageFormat.gif => ContentKindHint.gif,
      LocalImageFormat.webp => ContentKindHint.webp,
      LocalImageFormat.avif => ContentKindHint.avif,
      LocalImageFormat.bmp ||
      LocalImageFormat.tiff ||
      LocalImageFormat.ico ||
      LocalImageFormat.heif => ContentKindHint.fallback,
    };
