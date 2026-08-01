#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise SystemExit(f'{label}: missing {needle}')


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise SystemExit(f'{label}: forbidden {needle}')


def main() -> None:
    session = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart').read_text()
    stream = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_page_stream.dart').read_text()
    output = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_page_output.dart').read_text()
    capability = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_media_runtime.dart').read_text()
    host = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_reader_host.dart').read_text()
    runtime_pubspec = (ROOT / 'packages/pipeline_runtime/pubspec.yaml').read_text()
    native = (ROOT / 'packages/pipeline_native/lib/src/native_pipeline_media_runtime.dart').read_text()
    media_barrel = (ROOT / 'packages/local_media_ui/lib/local_media_ui.dart').read_text()
    media_screens = (ROOT / 'packages/local_media_ui/lib/src/local_media_screens.dart').read_text()
    media_player = (ROOT / 'packages/local_media_ui/lib/src/local_image_player.dart').read_text()
    reader = (ROOT / 'packages/reader_runtime/lib/src/reader_runtime_screen.dart').read_text()
    app_composition = (ROOT / 'apps/app/lib/webp_demo.dart').read_text()

    require(session, 'required PipelineMediaRuntimeFactory mediaRuntimeFactory', 'atomic media factory')
    require(session, 'factory: _media.sources,', 'Pipeline source composition')
    require(session, 'cursors: _media.cursors,', 'Pipeline decode composition')
    require(session, 'uploader: _media.uploader,', 'Pipeline upload composition')
    require(session, 'outputs: _media.outputs,', 'Pipeline output composition')
    require(session, 'await _media.close();', 'Pipeline media lifecycle')
    forbid(session, "package:bridge/bridge.dart", 'Pipeline platform dependency')
    forbid(session, "package:texture_bridge/texture_bridge.dart", 'Pipeline texture dependency')
    forbid(runtime_pubspec, '  bridge:', 'Pipeline pubspec dependency')
    forbid(runtime_pubspec, '  texture_bridge:', 'Pipeline pubspec dependency')

    require(host, 'required this.factory', 'pipeline host factory')
    forbid(host, 'this.factory = const PipelineReaderSessionFactory()', 'implicit host factory')

    require(stream, 'enum PipelinePageContentKind', 'content projection')
    forbid(stream, 'final EncodedSource', 'encoded source field leak')
    forbid(stream, 'EncodedSource? get source', 'encoded source getter leak')
    forbid(stream, ' get source', 'encoded source getter')
    require(output, 'final class PipelinePageOutputStream', 'output projection stream')
    require(output, 'PipelinePageSurface?', 'opaque surface projection')
    forbid(capability, 'textureId', 'public texture handle')
    forbid(capability, 'Pointer<', 'public native pointer')

    require(native, 'implements PipelineMediaRuntimeFactory', 'native atomic capability')
    require(native, 'NativeSourceFactory()', 'native source implementation')
    require(native, 'NativeCursorFactory()', 'native cursor implementation')
    require(native, 'AndroidTexturePresenter', 'native texture implementation')
    require(app_composition, 'NativePipelineMediaRuntimeFactory()', 'App media composition')
    forbid(media_barrel, 'pipeline_native', 'Presentation platform dependency')
    forbid(media_barrel, 'NativePipelineMediaRuntimeFactory', 'Presentation platform factory')

    require(media_screens, 'pipelineFactory.withLoaderSources(sources)', 'local source composition')
    require(media_screens, 'pageOutput: runtime.pageOutput', 'opaque output injection')
    forbid(media_screens, 'ArtifactCacheStore', 'UI cache implementation dependency')
    forbid(media_screens, 'readerPageDownloadId(', 'UI download identity dependency')
    require(media_player, 'PipelinePageContentKind.webp', 'content projection consumer')
    require(media_player, 'surface.build(', 'opaque surface consumer')

    require(reader, 'pageOutput: _pipeline.pageOutput(asset)', 'Reader output projection')
    require(reader, 'renderer: _pipeline.renderer', 'atomic renderer selection')
    require(reader, 'void _reportPageDimensions(', 'dimension callback')

    print('Pipeline runtime compile boundary: OK')


if __name__ == '__main__':
    main()
