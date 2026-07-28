# Fixed overlay baseline

This iteration starts from the complete source archive
`zic_v0.18.3-dev.21_webp-safe-folder-candidate_UNVERIFIED.zip`, then applies
`fixed.zip` by replacing the following repository files exactly:

| Overlay member | Repository path | Overlay SHA-256 |
| --- | --- | --- |
| `lib.rs` | `native/media_core/src/lib.rs` | `34b63519553ca6a64e3a6dc321e2a8d259df2eab011b0564ebb7ea905f22e588` |
| `webp.rs` | `native/media_core/src/webp.rs` | `a3e01edb566745f7b81f809c8484a44b170117b8819c8607001e543d007d8d61` |
| `webp_demo.dart` | `apps/app/lib/webp_demo.dart` | `29bbd0cea16078bb9c5b36b419fec6879758763d11b3a40106e2e49791e3b8a2` |
| `app_smoke_test.dart` | `apps/app/test/app_smoke_test.dart` | `b5b6aa9126461f265cbe6cad644e4818a05366b8307877a9360388069ff0f27d` |
| `android_texture.rs` | `native/media_core/src/android_texture.rs` | `30855d252fe06491c339650545fd91b577e9124bf45061ca8d011d1c55b66e7b` |

The replacement result—not either archive in isolation—is the only code baseline
for subsequent work. Later edits may intentionally change these files; the hashes
above record the exact overlay ingress, not the final candidate contents.
