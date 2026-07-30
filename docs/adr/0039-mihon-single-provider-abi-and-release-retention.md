# ADR 0039: Mihon single-provider ABI and release retention

- Status: Accepted
- Version: `0.31.0-dev.55`

## Context

After JitPack became visible to the generated App runtime classpath, Android could resolve the Mihon host artifacts and reached `checkReleaseDuplicateClasses`. The pinned `extensions-lib` AAR already contains the AndroidX Preference ABI and its legacy POM pulls Kohesive Injekt 1.16.1. zic also declared `preference-ktx` and the current null2264 Injekt fork used by Keiyoushi extensions. The resulting release contained two providers for the same `androidx.preference.*` and `uy.kohesive.injekt.*` classes.

Dynamic extension APKs introduce a second release risk. Their references to host Source/common-runtime classes are not visible while R8 analyzes the App, so a minified build can remove or rename APIs that the APK requires even when dependency resolution and duplicate-class checks pass.

## Decision

1. Treat `com.github.keiyoushi:extensions-lib:6e0c96cea8` as the ABI artifact only and set `transitive = false`.
2. Do not declare a separate AndroidX Preference artifact. The pinned ABI AAR is the sole provider of that namespace.
3. Keep the current Keiyoushi common runtime explicitly pinned, including the null2264 Injekt fork. Do not include the legacy `uy.kohesive.injekt` artifacts.
4. Keep Android duplicate-class verification enabled. Do not use `packagingOptions`, `pickFirst`, jar rewriting or disabled checks to conceal an ambiguous classpath.
5. Publish consumer R8 rules for binary APIs referenced by dynamically loaded extensions.
6. Before constructing an extension `DexClassLoader`, verify the core Source/model, Preference and Injekt classes through the runtime process parent class loader. Reject activation with a precise incomplete-host-ABI error if any are absent.
7. Run a repository dependency-closure gate before expensive toolchain work and keep Android release build as the artifact-level authority.

## Consequences

- The App has one provider for Preference and one provider for Injekt, eliminating the reported duplicate classes without weakening Android verification.
- Current extensions receive the same common-runtime revisions used by the upstream build instead of an accidental mix of old and current host libraries.
- Minified release builds retain dynamically referenced APIs.
- Broken host packaging fails during activation with named missing classes rather than surfacing later as empty catalogs or unrelated reflection failures.
- The isolated process, payload integrity, trust, session, cancellation, Reader, download and cache ownership boundaries are unchanged.
