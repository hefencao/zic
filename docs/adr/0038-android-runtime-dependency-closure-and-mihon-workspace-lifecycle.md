# ADR 0038: Android runtime dependency closure and Mihon workspace lifecycle

- Status: Accepted
- Version: `0.31.0-dev.54`

## Context

The executable Mihon driver used the exact current Keiyoushi runtime dependencies, but only the plugin Android subproject declared JitPack. Flutter's generated host can resolve `:app:releaseRuntimeClasspath` from a centralized or root-project repository owner, so the App build did not consult that local declaration. Manifest restoration also called a nonexistent Dart `File.isFile()` method. Separately, Mihon extraction reused one code-cache path per plugin version, which allowed concurrent activations to delete each other's files and left workspaces after abrupt process death.

## Decision

1. Configure canonical `https://jitpack.io` in the generated host repository owner. Prefer `dependencyResolutionManagement.repositories` when it exists; otherwise patch `allprojects.repositories`. Support both Groovy and Kotlin DSL and make the transformation idempotent.
2. Keep the upstream runtime dependency revisions pinned. Do not replace failed dependency resolution with copied ABI classes or silently remove host-provided libraries required by extensions.
3. Restore persisted plugins only from regular, non-link, format-matching files that resolve under the controller-owned payload root.
4. Allocate Mihon code-cache workspaces per activation using plugin ID, version and `driverId`. Delete failed activations immediately. On close, cancel requests, close sources and delete only after real task completion; service startup removes roots left by process death.
5. Pre-register native request tasks before execution and complete cleanup from `FutureTask.done()`, so cancellation before execution cannot strand request bookkeeping or runtime files.

## Consequences

- Generated Android hosts resolve the JitPack-only Keiyoushi, Injekt and QuickJS artifacts from the same repository scope as the App runtime classpath.
- A tampered manifest cannot restore directories, preview files, links or payloads outside the private plugin root.
- Parallel activation of the same Mihon plugin/version no longer races on a shared APK/dex/native directory.
- Graceful close and process restart have explicit cleanup paths without moving source/session ownership out of the existing Dart process host.
