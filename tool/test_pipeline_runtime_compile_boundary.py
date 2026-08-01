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
    session = (
        ROOT / 'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart'
    ).read_text()
    stream = (
        ROOT / 'packages/pipeline_runtime/lib/src/pipeline_page_stream.dart'
    ).read_text()
    host = (
        ROOT / 'packages/pipeline_runtime/lib/src/pipeline_reader_host.dart'
    ).read_text()
    runtime_pubspec = (ROOT / 'packages/pipeline_runtime/pubspec.yaml').read_text()
    media_barrel = (ROOT / 'packages/local_media_ui/lib/local_media_ui.dart').read_text()
    media_screens = (
        ROOT / 'packages/local_media_ui/lib/src/local_media_screens.dart'
    ).read_text()
    media_player = (
        ROOT / 'packages/local_media_ui/lib/src/local_image_player.dart'
    ).read_text()
    reader = (
        ROOT / 'packages/reader_runtime/lib/src/reader_runtime_screen.dart'
    ).read_text()

    require(session, 'required this.sourceFactory', 'pipeline source factory')
    require(session, 'factory: sourceFactory,', 'SourcePool composition')
    require(session, "import 'reader_pipeline_profile.dart';", 'profile import')
    forbid(session, "package:bridge/bridge.dart", 'pipeline platform dependency')
    forbid(runtime_pubspec, '  bridge:', 'pipeline pubspec dependency')

    require(host, 'required this.factory', 'pipeline host factory')
    forbid(host, 'this.factory = const PipelineReaderSessionFactory()', 'implicit host factory')

    require(stream, 'enum PipelinePageContentKind', 'content projection')
    require(stream, 'source: _session.ingress?.source', 'encoded source projection')
    forbid(stream, 'final ContentKind? kind;', 'transport type leak')
    forbid(stream, 'snapshot.ingress?.source', 'stale ingress API')

    require(media_barrel, 'sourceFactory: NativeSourceFactory()', 'native composition')
    require(media_screens, 'pipelineFactory.withLoaderSources(sources)', 'local source composition')
    require(media_screens, 'downloadIdentity: runtime.pageStream.identity', 'pipeline page identity')
    forbid(media_screens, 'ArtifactCacheStore', 'UI cache implementation dependency')
    forbid(media_screens, 'readerPageDownloadId(', 'UI download identity dependency')
    require(media_player, 'PipelinePageContentKind.webp', 'content projection consumer')

    require(reader, 'void _reportPageDimensions(', 'dimension callback')
    require(reader, 'WidgetsBinding.instance.addPostFrameCallback', 'dimension publish phase')

    print('Pipeline runtime compile boundary: OK')


if __name__ == '__main__':
    main()
