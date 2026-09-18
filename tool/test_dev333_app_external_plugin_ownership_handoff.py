#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = (ROOT / 'apps/app/lib/app_runtime.dart').read_text(encoding='utf-8')
REPOSITORY = (ROOT / 'apps/app/lib/external_plugin_repository_screen.dart').read_text(
    encoding='utf-8'
)
EDITOR = (ROOT / 'apps/app/lib/venera_plugin_editor_screen.dart').read_text(
    encoding='utf-8'
)


def require(marker: str, label: str) -> None:
    if marker not in RUNTIME:
        raise SystemExit(f'app external-plugin ownership handoff missing {label}: {marker}')


for marker, label in (
    ('_AppServices? _externalPluginSuccessor;', 'successor ownership link'),
    ('ExternalPluginController? get _currentExternalPluginController', 'successor-resolved current controller'),
    ('void transferExternalPluginOwnershipTo(_AppServices target)', 'single ownership transfer method'),
    ('target._joinExternalPluginReady(externalPluginsReady);', 'in-flight opening join'),
    ('externalPlugins = null;', 'predecessor controller release'),
    ('Future<bool> _acceptExternalPluginController(', 'forward-or-own controller acceptance'),
    ('return successor.ensureExternalPlugins(', 'stale loader successor delegation'),
    ('return _currentExternalPluginController;', 'in-flight ensure returns successor-owned controller'),
    ('await services._acceptExternalPluginController(controller);', 'open completion ownership routing'),
    ('void _publishExternalPluginsWhenReady(_AppServices services)', 'late handoff publication watcher'),
    ('_serviceHandoff.updateExternalPlugins(services.externalPlugins);', 'late current-controller publication'),
    ('previous?.transferExternalPluginOwnershipTo(services);', 'bootstrap/deferred to durable transfer'),
    ('previous.transferExternalPluginOwnershipTo(services);', 'download-service rebuild transfer'),
    ('previous?.transferExternalPluginOwnershipTo(degraded);', 'degraded service transfer'),
):
    require(marker, label)

if RUNTIME.count('return successor.ensureExternalPlugins(') != 1:
    raise SystemExit(
        'stale loader delegation must exist only before a predecessor opening '
        'flight starts; delegating from inside the inherited ready tail can deadlock'
    )

for forbidden in (
    'await previous.externalPluginsReady\n            .timeout(const Duration(seconds: 30));',
    'services.externalPlugins = previous.externalPlugins;',
    'degraded.externalPlugins = _services?.externalPlugins;',
):
    if forbidden in RUNTIME:
        raise SystemExit(
            'app external-plugin ownership handoff still has parallel/manual transfer: '
            + forbidden
        )

attach_start = RUNTIME.index('Future<void> _attachExternalPlugins(')
attach_body = RUNTIME[attach_start:]
if 'services.externalPlugins = controller;' in attach_body:
    raise SystemExit('external-plugin open still publishes directly to predecessor services')

for body, label in (
    (REPOSITORY, 'repository'),
    (EDITOR, 'Venera editor'),
):
    if 'final ExternalPluginController controller;' not in body:
        raise SystemExit(f'{label} no longer uses the stable concrete controller capability')
    for forbidden in (
        'HomeServiceHandoff',
        'HomeExternalSourceLifecycle',
        'readExternalPlugins',
        'externalSourceChanges',
    ):
        if forbidden in body:
            raise SystemExit(
                f'{label} acquired service/source generation ownership: {forbidden}'
            )

print('dev.333 App external plugin ownership handoff: OK')
