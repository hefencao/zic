# ADR 0042: Versioned Mihon ABI assets and Venera runtime semantics

- Status: Accepted
- Version: `0.31.0-dev.58`

## Context

Mihon extensionLib 1.4 and 1.6 publish incompatible classes under the same `eu.kanade.tachiyomi` names. Keeping one ABI on the App parent classpath caused older extensions to verify against newer final methods. Venera sources execute as ecosystem scripts, while zic imposed a shorter outer timeout and a bootstrap-wide strict directive.

## Decision

1. Resolve the pinned 1.4 and 1.6 API AARs only in detached build configurations. D8 their `classes.jar` files into deterministic assets with exact length and SHA-256 metadata; do not add either API to the App runtime graph.
2. Select the asset by inspected `extensionLib`, stage it read-only beside the verified APK, and use a child-first loader only for `eu.kanade.tachiyomi.*` and extension classes. AndroidX Preference remains parent-first so its resources are merged; all common libraries have one provider.
3. Preflight parent common classes separately from child Source/model classes. Never fall back to another ABI after verification failure.
4. Do not impose strict mode on Venera source text. Provide the ecosystem-compatible `res` global binding, preserve operation context in errors, and make the outer timeout longer than the native network timeout while retaining a bounded platform maximum and cooperative cancellation.

## Consequences

Release builds gain two small dex assets but avoid duplicate classes and cross-version verifier failures. Unsupported or missing ABI assets fail activation precisely. Venera network work is no longer cancelled at ten seconds, and source-script scope errors become diagnosable without moving network, cache, Reader, or session ownership into the plugin.
