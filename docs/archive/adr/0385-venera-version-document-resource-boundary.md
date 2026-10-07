# ADR 0385: Venera version documents have explicit resource intent

Status: Accepted

## Context

E-Hentai version discovery reads the current gallery's HTML and parses its
`#gnd` relation in the source adapter. Ordinary runtime `loadResource` is an
image path: it invokes thumbnail/image hooks and rejects non-image bytes before
publishing a native token. Using it without explicit document intent prevents
successful HTML responses from reaching the version parser. Persisted relations
and background refresh fallback can hide this failure behind an existing panel.

## Decision

The schema-v1 `loadResource` message accepts optional boolean `sourceDocument`,
defaulting to false. The Venera adapter sets it only for a confirmed gallery
version request. Document intent requires HTTP(S) and uses the existing general
`Network.fetchBinary` path and native token protocol in the same runtime,
Cookie/session, requestId and physical invocation gate. It does not invoke image
hooks, transform the document, validate an image signature or retry via image
semantic recovery. HTTP errors continue to fail the version request. The existing
uncontrolled single-flight distinguishes URI and document intent; controlled
requests remain independent and cannot inherit another task cancellation/rank.

Normal page and artwork requests retain their original wire arguments, image
validation and bounded source recovery. Reader, Pipeline, download/artifact
identity, source revisions, scheduling and resource windows do not change.

## Validation

The production-bootstrap failing-first proves HTML intent enters
`http_image_binary` and calls a thumbnail hook. Adapter and protocol failing-first
checks prove the missing discriminator. The repaired bootstrap covers the
general binary token, requestId/finished lifecycle, HTTP-only constraint and HTTP
error propagation; existing image recovery contracts still pass. Focused56
adapter/protocol tests and the required2221-test/27-suite gate plus Rust22 pass.
Profile and minified Release package all three ABIs with matching JNI/FFI, native
strip inputs and document/image/AOT branches. The ordinary Release discovers the real2026-10-03
successor where the earlier panel stopped at2026-09-04. The existing95 chapter
payload/progress records and all other backup sections remain unchanged;24 new
version manifests contain no progress. Three stationary sliders and four correct
chapter endpoints pass; the retained10000-event tail has112 artifact-cache reads
and no download starts/task failures. Earlier events may have been evicted;
original loading, future admission/notification and final display remain separate.
Evidence is in
`docs/archive/audits/venera-version-document-resource-boundary-2026-10-03.json`.
