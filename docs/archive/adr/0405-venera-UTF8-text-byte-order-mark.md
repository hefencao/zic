# ADR 0405: Venera UTF-8 text byte order mark

Status: Accepted

## Context

The ordinary installed Release reproduces a JM title-search failure and the
original single-source page exposes JSON.parse rejecting an initial U+FEFF.
Java UTF-8 String decoding preserves the initial byte order mark. The Venera
reference uses Dio plain responses and Dart utf8.decode for Convert.decodeUtf8;
these consume the initial mark. Retry or resolver-cache bypass cannot repair
that deterministic text-boundary mismatch.

## Decision

Share one native UTF-8 text decoder between HTTP string projection and
Convert.decodeUtf8. Remove exactly one initial U+FEFF, preserving all remaining
characters, the original body bytes and binary serialization. GBK, encoding,
HTTP status, headers, cookies, resolver cache, source identity and request
lifetime remain in their existing paths. Keep source-read replay and transport
retry classification in the existing owners.

## Validation

Two response-text assertions fail before the repair and pass afterwards,
including double marks, non-leading marks, ordinary Unicode and immutable body
bytes. Full toolchain, packaging and ordinary-device validation are recorded in
docs/archive/audits/venera-UTF8-BOM-compatibility-2026-10-07.json before acceptance.
