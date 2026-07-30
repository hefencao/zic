# ADR 0040: External source capability normalization and payload context

- Status: Accepted
- Version: `0.31.0-dev.56`

## Context

A Venera source can expose browse through an explore loader or through category metadata. Current sources use arrays, ordinary objects and `Map` containers, and category definitions commonly separate `itemType`, `categories` and parallel `categoryParams`. Treating only the legacy `target.attributes` shape as browse produced a false “no browse capability” failure. Some current scripts also advertise Brotli/Zstandard even when the host bridge only decodes gzip/deflate, and a device resolver may map a public source domain to loopback, causing a connection to `127.0.0.1` rather than the public service.

Mihon extensions are APKs rather than plain class jars. Loading their classes with the ZIC application Context makes the extension package resources, package identity, LayoutInflater and isolated data unavailable. Entry metadata also points to Kotlin objects, factories and constructors across different extension generations; collapsing every failure into `activationFailed` hides the actionable cause.

## Decision

1. Normalize Venera browse capabilities inside the isolated adapter. Accept direct loaders, arrays, objects and `Map` containers; resolve both current `itemType/categories/categoryParams` and legacy `target.attributes`; execute dynamic or static option contracts before the first category request.
2. Rewrite `Accept-Encoding` to the codecs the native bridge actually decodes and decode the returned body under the existing response-size ceiling.
3. For a syntactically public hostname only, use a bounded DoH fallback when system DNS fails or returns no public addresses. Accept only numeric A/AAAA answers that are not any-local, loopback, link-local, site-local or multicast. Perform the HTTP request with a custom DNS implementation so URL hostname, certificate verification, SNI, cookies and origin identity remain unchanged.
4. Create a process-private Mihon payload Context after revalidating the copied APK package. Bind resources, assets, application metadata, class loader, theme, inflater, preferences and file/cache roots to that payload.
5. Instantiate entry classes through Kotlin object `INSTANCE`, supported static factories, a `Context` constructor or a no-arg constructor, in that order. Reject abstract/interface entries, duplicate source IDs and unsupported ABI versions with named diagnostics.
6. Preserve the native cause in the cross-process activation exception. Unsupported contracts must fail explicitly; they must not be represented as an empty source list.

## Consequences

- Current Venera sources with modern category metadata can browse without source-specific UI branches, while legacy sources remain compatible.
- The DNS workaround addresses the reported public-domain-to-loopback failure without granting arbitrary private-network access or weakening TLS hostname verification.
- Mihon extensions receive their own Android package environment while remaining inside the dedicated runtime process and immutable payload boundary.
- Activation failures become actionable by naming the entry and root cause.
- Reader, catalog adaptation, cache, downloads, session limits, cancellation and trust ownership remain unchanged.
