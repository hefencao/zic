#!/usr/bin/env python3
"""Keep async navigation/dialog flows bound to a live BuildContext."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DETAILS = (ROOT / 'apps/app/lib/comic_details.dart').read_text(encoding='utf-8')
CONFLICT = (ROOT / 'apps/app/lib/comic_download_conflict_dialog.dart').read_text(encoding='utf-8')
SOURCE = (ROOT / 'apps/app/lib/source_browser.dart').read_text(encoding='utf-8')


def require(body: str, marker: str, label: str) -> None:
    if marker not in body:
        raise SystemExit(f'async context lifetime missing {label}: {marker}')


source_start = SOURCE.index('Future<void> openComicSourceSettings(')
source_end = SOURCE.index('\nbool ', source_start)
source_flow = SOURCE[source_start:source_end]
require(source_flow, "await attachAndroidPlugin('network_bridge');", 'source settings attach')
require(source_flow, 'if (!context.mounted) return;', 'source settings mounted guard')
if source_flow.index('if (!context.mounted) return;') > source_flow.index('await Navigator.of(context).push('):
    raise SystemExit('source settings mounted guard must precede navigation')

helper_start = DETAILS.index('Future<bool> _confirmComicDownloadConflict({')
helper_end = DETAILS.index('\nfinal class _LocalComicDetailsScreenState', helper_start)
helper = DETAILS[helper_start:helper_end]
if 'required bool mounted' in helper:
    raise SystemExit('comic-details conflict helper must not capture mounted by value')
require(helper, 'if (!context.mounted) return false;', 'comic-details dynamic mounted guard')
if 'mounted: mounted,' in DETAILS:
    raise SystemExit('comic-details callsites must not pass a stale mounted snapshot')

prompt_start = CONFLICT.index('Future<ComicConflictResolutionResult> promptComicConflictResolutionResult(')
prompt_end = CONFLICT.index('\nString _uniqueSaveAsNewDirectoryName', prompt_start)
prompt = CONFLICT[prompt_start:prompt_end]
candidate_index = prompt.index(
    'final selected = await showComicConflictCandidateListDialog('
)
guard_index = prompt.index('if (!context.mounted) {', candidate_index)
compare_index = prompt.index(
    'final decision = await showComicConflictCompareDialog(',
    guard_index,
)
if not candidate_index < guard_index < compare_index:
    raise SystemExit('conflict mounted guard must sit between candidate and compare dialogs')

print('Async BuildContext lifetime contract: OK')
