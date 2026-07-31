#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(source: str, needle: str, label: str) -> None:
    if needle not in source:
        raise SystemExit(f'{label}: missing {needle}')


def main() -> None:
    app_reader = (ROOT / 'apps/app/lib/reader_runtime.dart').read_text()
    app_webp = (ROOT / 'apps/app/lib/webp_demo.dart').read_text()
    runtime = (
        ROOT / 'packages/reader_runtime/lib/src/reader_runtime_screen.dart'
    ).read_text()
    media_ui = (ROOT / 'packages/local_media_ui/lib/local_media_ui.dart').read_text()
    source_manager = (ROOT / 'apps/app/lib/source_browser.dart').read_text()
    repository = (
        ROOT / 'apps/app/lib/external_plugin_repository_screen.dart'
    ).read_text()
    model = (
        ROOT / 'apps/app/lib/external_plugin_repository_model.dart'
    ).read_text()
    app_pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text()

    require(app_reader, "export 'package:reader_runtime/reader_runtime.dart';", 'reader facade')
    require(app_webp, "export 'package:local_media_ui/local_media_ui.dart';", 'media UI facade')
    require(runtime, "import 'package:media/media.dart' show SourcePool;", 'SourcePool owner')
    require(
        media_ui,
        'show parseWebpPrefixInfo, webpPrefixDeclaresAnimation;',
        'WebP prefix owner',
    )
    if len(app_reader.splitlines()) > 8 or len(app_webp.splitlines()) > 8:
        raise SystemExit('App compatibility facades must stay thin')
    for part in (ROOT / 'packages/local_media_ui/lib/src').glob('*.dart'):
        if len(part.read_text().splitlines()) > 1600:
            raise SystemExit(f'local media UI part is too large: {part.name}')

    production = app_pubspec.split('dev_dependencies:', 1)[0]
    for forbidden in ('  pipeline:', '  sessions:', '  storage:', '  transport:'):
        if forbidden in production:
            raise SystemExit(f'App production dependency leaked: {forbidden.strip()}')
    require(production, '  reader_runtime:', 'App reader composition dependency')
    require(production, '  local_media_ui:', 'App local-media UI dependency')

    if 'for (final installed in widget.externalPlugins!.installed)' in source_manager:
        raise SystemExit('source manager still owns the installed plugin list')
    for needle in (
        "title: '原生'",
        "title: 'Mihon'",
        "title: 'Venera'",
        "groupMihonSourcesByLanguage(",
        "'其他语言（${group.otherLanguages.length}）'",
        'initiallyExpanded: false',
        "const Divider(height: 1)",
    ):
        require(source_manager, needle, 'categorized source management')
    for needle in (
        'SegmentedButton<_ExternalPluginPage>',
        '_ExternalPluginPage.installed',
        '_ExternalPluginPage.repository',
        "label: Text('已安装')",
        "label: Text('仓库')",
        "'refresh-device-mihon-extensions'",
        'item.plugin.format == widget.format',
    ):
        require(repository, needle, 'ecosystem repository tabs')
    for forbidden in (
        'body: Row(',
        'groupMihonEntriesByLanguage(',
        "'其他语言（${group.otherLanguages.length}）'",
    ):
        if forbidden in repository:
            raise SystemExit(f'repository still contains obsolete split/group UI: {forbidden}')
    for needle in (
        'groupMihonSourcesByLanguage(',
        'pluginOwner',
        "normalized == 'all'",
        'parts.skip(extensionIndex + 2)',
    ):
        require(model, needle, 'Mihon source-language grouping')

    print('UI architecture and external repository layout: OK')


if __name__ == '__main__':
    main()
