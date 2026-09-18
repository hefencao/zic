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


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(f'external plugin mutation close contract missing {label}: {marker}')


require(GATE, 'final class ExternalPluginMutationGate', 'mutation gate owner')
require(GATE, 'Future<T> run<T>', 'mutation admission')
require(GATE, 'Future<void> beginClose()', 'mutation drain boundary')
require(CONTROLLER, 'final ExternalPluginMutationGate _durableMutations =', 'controller gate field')
require(CONTROLLER, 'Future<void>? _closeFuture;', 'joinable close future')
require(
    CONTROLLER,
    'Future<void> close() => _closeFuture ??= _close();',
    'joinable public close boundary',
)

for signature, marker in (
    ('approveAndActivate(', '_runDurableMutation(() => _approveAndActivate(preview))'),
    ('retryActivation(String pluginId)', '_runDurableMutation(() => _retryActivation(pluginId))'),
    ('remove(String pluginId)', '_runDurableMutation(() => _remove(pluginId))'),
    ('_activateRecord(InstalledExternalPlugin record)', '_runDurableMutation(() async {'),
):
    start = CONTROLLER.index(signature)
    window = CONTROLLER[start:start + 450]
    require(window, marker, signature)

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
