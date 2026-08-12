from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
reader = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart').read_text()
stream = (ROOT / 'packages/pipeline_runtime/lib/src/pipeline_page_stream.dart').read_text()
decode = (ROOT / 'packages/sessions/lib/src/decode_session.dart').read_text()
reader_test = (ROOT / 'packages/pipeline_runtime/test/media_runtime_ownership_test.dart').read_text()
decode_test = (ROOT / 'packages/sessions/test/decode_session_test.dart').read_text()
arch = (ROOT / 'docs/ARCHITECTURE.md').read_text()
spec = (ROOT / 'docs/SPEC.md').read_text()


def require(ok: bool, message: str) -> None:
    if not ok:
        raise SystemExit(message)

require('_downloads.get' not in reader,
        'dev.242 presentation/read-only pipeline paths must not create physical download sessions')
require('PipelinePageStream.forDownload(' in reader and 'resolvePhysical: () => _downloads.find(id)' in reader,
        'dev.242 page stream must be a non-creating logical projection')
require('binding.accept(observation);\n    _syncPageStreams();' in reader,
        'dev.242 page streams must bind only after demand reconciliation')
require('void refreshBinding()' in stream and '_resolvePhysical()' in stream,
        'dev.242 page stream must refresh through the pipeline-owned physical resolver')
require('presentation pageStream cannot precreate an exact physical session before verified acquire' in reader_test,
        'dev.242 regression must prove presentation cannot block verified physical alias acquisition')
require('registry.findExact(newId), isNull' in reader_test and 'registry.sessions, hasLength(1)' in reader_test,
        'dev.242 regression must prove exact projection does not create a second physical owner')
require('_deferUnsealedInitialDecodeFailure(source)' in decode,
        'dev.242 decode must defer provisional unsealed first-frame failure')
require("'decode-provisional-prefix-failure'" in decode,
        'dev.242 provisional decode wait must remain observable')
require('source.sealed || (_holder?.depth ?? 0) > 0' in decode,
        'dev.242 provisional decode rule must not swallow sealed or post-frame failures')
require('unsealed first-frame decode error waits for source growth instead of failing' in decode_test,
        'dev.242 needs a growing-prefix recovery regression')
require('presentation/read-only' in arch and 'acquire/reconcile' in arch,
        'dev.242 architecture must name the physical session creation boundary')
require('presentation/read-only' in spec and 'acquire/reconcile' in spec,
        'dev.242 spec must freeze the physical session creation boundary')

print('PASS: dev.242 acquire projection + provisional decode closure')
