part of '../local_media_ui.dart';

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
                    child: Image.asset(entry.asset, fit: BoxFit.cover),
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
      origin: EncodedResourceOrigin.localFile,
      lengthInBytes: image.byteLength,
    ),
  );
}

