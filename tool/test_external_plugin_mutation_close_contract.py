#!/usr/bin/env python3
"""Keep ExternalPluginController durable mutation teardown ownership closed."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = (
    ROOT / 'packages/plugin_host_bridge/lib/src/external_plugin_controller.dart'
).read_text(encoding='utf-8')
GATE = (
    ROOT / 'packages/plugin_host_bridge/lib/src/external_plugin_mutation_gate.dart'
).read_text(encoding='utf-8')
REGISTRY = (
    ROOT / 'packages/plugin_host/lib/src/runtime_registry.dart'
).read_text(encoding='utf-8')


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(f'external plugin mutation close contract missing {label}: {marker}')


require(GATE, 'final class ExternalPluginMutationGate', 'mutation gate owner')
require(GATE, 'Future<T> run<T>', 'mutation admission')
require(GATE, 'String pluginId,', 'per-plugin mutation key')
require(GATE, 'final Map<String, Future<void>> _tails', 'per-plugin mutation tails')
require(GATE, 'Future<void> beginClose()', 'mutation drain boundary')
require(CONTROLLER, 'final ExternalPluginMutationGate _durableMutations =', 'controller gate field')
require(CONTROLLER, 'final class _PendingPluginPayload', 'pending preview generation owner')
require(CONTROLLER, 'final Object? _claim;', 'opaque preview claim')
require(
    CONTROLLER,
    'final Map<String, Object> _previewGenerations',
    'preview request generation owner',
)
require(
    CONTROLLER,
    '!identical(pending.claim, preview._claim)',
    'exact preview generation claim check',
)

inspect_start = CONTROLLER.index('Future<ExternalPluginInstallPreview> inspect({')
inspect_end = CONTROLLER.index(
    '\n  Future<ExternalPluginInstallPreview> inspectInstalledMihon(',
    inspect_start,
)
inspect_body = CONTROLLER[inspect_start:inspect_end]
preview_begin = inspect_body.index('_beginPreviewGeneration(plugin.pluginId)')
download_start = inspect_body.index('_downloadToFile(')
if preview_begin > download_start:
    raise SystemExit('preview generation must be established before same-plugin download starts')
if inspect_body.count('_requireCurrentPreviewGeneration(') < 2:
    raise SystemExit('inspect must recheck preview generation after download and inspection')
require(
    inspect_body,
    '_PendingPluginPayload(\n      payload.path,\n      previewGeneration,',
    'inspect pending generation publication',
)
require(
    CONTROLLER,
    '_previewGenerations.clear();',
    'preview generation close cleanup',
)
require(
    CONTROLLER,
    'Future<ExternalPluginPayloadFile> _acquireInstalledPayload(',
    'installed record payload reader',
)
require(
    CONTROLLER,
    'final cached = await _cachedPinnedInspection(record);',
    'record-scoped cached inspection',
)
require(
    CONTROLLER,
    'final payload = await _acquireInstalledPayload(record);',
    'cached inspection exact record payload',
)
require(
    CONTROLLER,
    'inspectRecord: _inspectInstalledRecord,',
    'runtime host record-scoped inspection',
)
require(
    CONTROLLER,
    'record.payloadPath == inspection.payloadPath &&',
    'runtime inspection exact path pin',
)
require(CONTROLLER, 'Future<void>? _closeFuture;', 'joinable close future')
require(
    CONTROLLER,
    'Future<void> close() => _closeFuture ??= _close();',
    'joinable public close boundary',
)
require(REGISTRY, 'Future<void>? _closeFuture;', 'joinable registry close future')
require(
    REGISTRY,
    'Future<void> close() => _closeFuture ??= _close();',
    'joinable registry close boundary',
)
require(
    REGISTRY,
    'final Map<String, Future<void>> _deactivations = <String, Future<void>>{};',
    'registry deactivation single-flight owner',
)

deactivate_start = REGISTRY.index('Future<void> deactivate(String pluginId) {')
deactivate_end = REGISTRY.index('\n  Future<void> _deactivate(', deactivate_start)
deactivate_body = REGISTRY[deactivate_start:deactivate_end]
require(deactivate_body, '_deactivations[pluginId]', 'same-plugin deactivation coalescing')
require(deactivate_body, '_deactivations[pluginId] = deactivation;', 'deactivation publication')
require(
    REGISTRY,
    'void _requirePluginNotDeactivating(String pluginId)',
    'per-plugin destructive admission fence',
)

for signature in (
    'Future<List<BrowsableComicSource>> activate(',
    'Future<List<BrowsableComicSource>> replace(',
):
    start = REGISTRY.index(signature)
    next_method = REGISTRY.index('\n  Future<', start + len(signature))
    body = REGISTRY[start:next_method]
    guard = body.index('_requirePluginNotDeactivating(plugin.pluginId);')
    first_session_read = body.index('_sessions[plugin.pluginId]')
    if guard > first_session_read:
        raise SystemExit(
            f'deactivation fence must precede existing-session lookup: {signature}'
        )

registry_close_start = REGISTRY.index('Future<void> _close() async {')
registry_close_end = REGISTRY.index('\n  void _requireOpen()', registry_close_start)
registry_close = REGISTRY[registry_close_start:registry_close_end]
registry_order = [
    '_activations.clear();',
    '_deactivations.values.toList(growable: false)',
    'await deactivation;',
    '_deactivations.clear();',
    '_sessions.values.toList(growable: false)',
]
registry_positions = [registry_close.index(marker) for marker in registry_order]
if registry_positions != sorted(registry_positions):
    raise SystemExit('registry close must drain admitted deactivation before remaining sessions')

for signature, markers in (
    (
        'approveAndActivate(',
        ('_runDurableMutation(', 'preview.plugin.pluginId', '_approveAndActivate(preview)'),
    ),
    (
        'retryActivation(String pluginId)',
        ('_runDurableMutation(pluginId', '_retryActivation(pluginId)'),
    ),
    (
        'remove(String pluginId)',
        ('_runDurableMutation(pluginId', '_remove(pluginId)'),
    ),
    (
        'saveVeneraJavaScript(',
        ('_runDurableMutation(', 'pluginId', '_saveVeneraJavaScript(pluginId, source)'),
    ),
    (
        'restartMihonSourceForBrowserHandoff(String sourceId)',
        ('_runDurableMutation(', 'pluginId', '_restartMihonSourceForBrowserHandoff('),
    ),
    (
        '_activateRecord(InstalledExternalPlugin record)',
        ('_runDurableMutation(record.plugin.pluginId',),
    ),
):
    start = CONTROLLER.index(signature)
    window = CONTROLLER[start:start + 700]
    for marker in markers:
        require(window, marker, f'{signature} keyed mutation marker')

activate_record_start = CONTROLLER.index(
    'Future<void> _activateRecord(InstalledExternalPlugin record)'
)
activate_record_window = CONTROLLER[
    activate_record_start:activate_record_start + 1200
]
record_recheck = activate_record_window.index(
    'if (!identical(_installed[record.plugin.pluginId], record))'
)
registry_activate = activate_record_window.index(
    'final sources = await _registry.activate(record.plugin);'
)
if record_recheck > registry_activate:
    raise SystemExit(
        'background activation must recheck current record after acquiring plugin key'
    )

close_start = CONTROLLER.index('Future<void> _close() async {')
close_end = CONTROLLER.index('\n  Future<void> _discardPendingPayloads()', close_start)
close_body = CONTROLLER[close_start:close_end]
order = [
    '_closed = true;',
    '_durableMutations.beginClose()',
    'await _registry.close();',
    'await mutationsDrained;',
    'await _manifestWriteTail;',
    'await _discardPendingPayloads();',
    'await _sourceChanges.close();',
]
positions = [close_body.index(marker) for marker in order]
if positions != sorted(positions):
    raise SystemExit('controller close ordering no longer drains runtime/mutation/manifest ownership')

activate_start = CONTROLLER.index('Future<void> _activateInstalled() async {')
activate_end = CONTROLLER.index('\n  Future<void> _activateRecord(', activate_start)
require(CONTROLLER[activate_start:activate_end], 'if (_closed) return;', 'background activation close stop')

for signature in (
    'Future<void> refreshDeviceMihonExtensions(',
    'Future<List<ExternalComicPluginCatalogEntry>> loadRepository(',
    'Future<ExternalPluginInstallPreview> inspect({',
    'Future<ExternalPluginInstallPreview> inspectInstalledMihon(',
):
    start = CONTROLLER.index(signature)
    next_method = CONTROLLER.find('\n  Future<', start + len(signature))
    end = len(CONTROLLER) if next_method < 0 else next_method
    if '_runDurableMutation' in CONTROLLER[start:end]:
        raise SystemExit(f'transient operation must not own durable mutation admission: {signature}')

print('External plugin mutation close contract: OK')
