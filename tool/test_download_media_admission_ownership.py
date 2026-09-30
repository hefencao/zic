#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
io_transport = (ROOT / 'packages/transport/lib/src/io_transport.dart').read_text()
job = (ROOT / 'packages/sessions/lib/src/download_job.dart').read_text()
owner = (ROOT / 'packages/sessions/lib/src/download_transfer_owner.dart').read_text()
source_transport = (ROOT / 'packages/downloads/lib/src/source_resource_transport.dart').read_text()
artifact_store = (ROOT / 'packages/downloads/lib/src/persistent_download_artifact_store.dart').read_text()

errors = []

def require(source, needle, message):
    if needle not in source:
        errors.append(message)

def forbid(source, needle, message):
    if needle in source:
        errors.append(message)

# Generic transport remains byte transport. Image semantics belong to the
# composition image-transfer admission boundary, not HTTP/file routing.
for needle in [
    'sniffEncodedImageKind',
    'hasSupportedEncodedImageSignature',
    'requireEncodedImageBody',
    'sourceMediaSemanticRejected',
]:
    forbid(io_transport, needle, f'IoTransport acquired image semantic ownership: {needle}')

require(job, 'this.requireEncodedImageBody = false,',
        'generic DownloadJob must keep image admission opt-in')
require(job, 'session.readSourceMetadataPrefix()',
        'image admission must consume generation-local DownloadSession metadata')
require(job, 'hasSupportedEncodedImageSignature(prefix)',
        'image admission must use the shared encoded-image signature classifier')
require(job, '_deferImageAdmissionToArtifactCacheRecovery',
        'existing durable artifact-cache generations must retain generation-aware recovery ownership')
require(job, 'ByteResponseBodyAuthority.artifactCache',
        'artifact-cache resident authority must be distinguished from new source-body admission')
require(job, "'sourceMediaProtocolMismatch': true",
        'ordinary image admission must publish the shared source media mismatch contract')
require(job, "'sourceMediaSemanticRejected': true",
        'ordinary image admission must publish the shared semantic rejection contract')

if owner.count('requireEncodedImageBody: true') < 3:
    errors.append('composition owner must enforce image admission on both local-completion paths and network DownloadJob')
require(owner, '_retireSourceMediaSemanticRejection(',
        'composition owner must own rejected-generation cleanup')
require(owner, 'deleteFinalArtifact: true,',
        'semantic media rejection must delete the rejected final generation as well as partial state')
require(owner, "'stage': 'image-media-admission'",
        'semantic media rejection must remain observable at the owner boundary')
require(owner, "failure.details['sourceMediaSemanticRejected'] == true",
        'owner must key cleanup from the shared semantic rejection contract')

# Plugin/runtime and ordinary host paths must converge on the same classifier
# and semantic contract; opaque resource identities remain transport-agnostic.
require(source_transport, 'hasSupportedEncodedImageSignature(bytes)',
        'source-resource transport must keep byte-signature media admission')
require(source_transport, "'sourceMediaSemanticRejected': true",
        'source-resource transport must share the semantic rejection contract')

# Durable artifact storage may validate structured image files, but it must not
# learn the live transport admission toggle/error contract.
for needle in ['requireEncodedImageBody', 'sourceMediaSemanticRejected']:
    forbid(artifact_store, needle, f'artifact store acquired live media-admission policy: {needle}')

if errors:
    for error in errors:
        print(f'FAIL: {error}')
    raise SystemExit(1)
print('download image media admission ownership: OK')
