# Downloads large-file decoupling — 2026-09-14

## Why this was first

After the cache/partial/process-death line closed, production-file review found `packages/downloads/lib/src/chapter_downloads.dart` at 13,896 lines / about 488 KiB, more than three times the next large production Dart file. More importantly, it mixed the persistent artifact/replica/partial/promotion/maintenance owner with chapter command/composition/management code. Recent READY/partial, promotion-journal, cleanup-debt and SAF/Direct fixes repeatedly touched this same source file, so responsibility density—not line count alone—made it the first refactor target.

Remaining priority is: (P0) isolate Downloads durable storage first; (P1) preserve the outstanding device-performance work such as Home cover latency, Reader source wait/open timing and bidirectional cadence; (P2) later review the large hot-path owners `download_session.dart`, `download_transfer_owner.dart`, `pipeline_reader_session.dart` and `sqlite_index.dart`; (P3) UI large files only after the core owners are stable.

## First extraction

`PersistentDownloadArtifactStore` and its directly adjacent durable-store helpers now live in `packages/downloads/lib/src/persistent_download_artifact_store.dart`, included by `chapter_downloads.dart` as a Dart `part`. `PersistentDownloadComposition`, `PersistentChapterDownloadService`, chapter contracts and management projection remain in `chapter_downloads.dart`. This is deliberately a physical source/responsibility split only: the library/private namespace, public API, SQLite schema, lock order, transfer ownership and runtime behavior are unchanged.

The moved source block was copied byte-for-byte: 346,187 bytes / 9,773 lines, SHA-256 `6c05fa71ce26eb73af6985cefcb5e1dc8fbe95b77e4337712101dd36d2875186` before and after. `chapter_downloads.dart` fell to about 4,125 lines; the new persistent-store part is about 9,775 lines. The store is therefore still large. A later phase may split maintenance/promotion/replica responsibilities into real collaborators, but only after this non-semantic baseline is stable.

## Static ownership gates

Several historical Python gates encoded the old physical file location. They were updated rather than weakening the ownership contract: chapter/composition checks still inspect `chapter_downloads.dart`; durable-store checks inspect `persistent_download_artifact_store.dart`; contracts that genuinely span both domains explicitly combine the two source texts. This prevents a future refactor from being forced back into the old giant file merely to satisfy location-coupled tests.

## Validation

- targeted analyzer: 0 errors / 0 warnings; existing info-level lints only;
- focused persistent/chapter suites: 178/178;
- full `packages/downloads/test`: 407/407;
- updated dev.115/dev.206/dev.223/dev.224/dev.235/dev.273 ownership guards pass;
- `tool/check_repo.py` passes;
- no formatter was run and no Reader/App lifecycle or scheduling behavior changed.

## Second cut and stop condition

A dependency map of the isolated store showed that replica migration is not yet a clean extraction target: its copy/resume/cleanup path crosses artifact mutation serialization, `StorageRoot` access aliases, SAF/Direct write primitives, schema-16 cleanup debt and the later replica read/retire path. Extracting that cluster now would require a wide reverse-callback surface and would increase coupling merely to reduce line count.

Instead, two naturally closed seams were extracted first. Schema-17 dirty-open promotion recovery is now `_ArtifactPromotionRecovery` in `artifact_promotion_recovery.dart`; it owns only promotion-journal source/destination validation and commit/rollback recovery and still publishes authority only through the existing SQLite commit. Indexed/physical partial resume metadata parsing and POSIX chunk helpers moved from `chapter_downloads.dart` into `persistent_download_partial_resume.dart`, removing a reverse private dependency from the chapter-service source into the persistent-store implementation.

After this cut `chapter_downloads.dart` is about 3,921 lines and the store part about 9,679 lines. Focused promotion/partial/migration/chapter coverage passes 180/180 and full Downloads remains 407/407; repository/documentation/ownership/diff gates pass. The remaining ~9.7k-line store is intentionally not split further until a real collaborator boundary can be introduced without callback-heavy inversion. The next product priority therefore returns to device performance rather than cosmetic line-count reduction.

## Third cut: structured placement/export owner

The next device-performance investigation exposed no reason to split replica migration, but a fresh dependency review did find a substantially cleaner boundary inside the remaining store: structured download placement/export. This area already owned its own mutable state and serialization domains—structured write tails, owner→directory and directory→owner claims, durable placement claims, session placement claims, placement load state and per-owner placement write tails—and its public behavior is about export layout/manifest ownership rather than artifact/replica/partial byte authority.

That responsibility now lives in `persistent_download_structured_placement.dart` as `_PersistentDownloadStructuredPlacementMixin`. The seven placement/export state groups moved with the behavior instead of remaining as reverse-owned fields in `PersistentDownloadArtifactStore`. The mixin declares a narrow host contract for the durable index, registry/layout lookup, tracing, SAF access, cleanup-debt tracking and a few existing store queries; it does not receive a forest of callbacks and does not create a second runtime authority. `PersistentDownloadArtifactStore` remains the single production object implementing the existing cache/download interfaces and still waits for the inherited structured/placement write tails during close.

The first pass moved the state, locking, placement, page-order and manifest logic. A follow-up dependency review then found that the core store still contained the other half of the same responsibility: single→multi-chapter directory migration, comic conflict inspection, explicit existing-page scans/adoption, structured promoted-page placement, `createNew` sibling materialization, SAF/local structured copies and their path-collision checks. Leaving those methods in the core would have produced a misleading split where the collaborator owned the state but the core still owned most structured behavior. They are now in the same `_PersistentDownloadStructuredPlacementMixin` as well. Artifact checksum/proof, SQLite authority mutation and cleanup-debt primitives remain host services; the mixin orchestrates structured placement/materialization but never becomes a second artifact or replica authority.

The completed collaborator therefore owns directory allocation/claim locking, `DownloadPlacement` load/persist/normalization, export page-order binding, structured chapter/comic directory resolution, `.zic.json` read/validate/write/remove, structured-export cleanup, flat→subdirectory migration, conflict inspection, explicit directory scans/adoption and structured/sibling materialization. Artifact object/replica ownership, mutable exact/physical partials, promotion, borrowed-spool mutation, cleanup debt, replica migration/recovery and cache maintenance stay in the core store.

After completing that responsibility rather than stopping after the first physical move, the source sizes are 3,922 lines for `chapter_downloads.dart`, 6,875 for `persistent_download_artifact_store.dart`, 2,857 for `persistent_download_structured_placement.dart`, 100 for promotion recovery and 208 for partial-resume helpers. The targeted Downloads analyzer exits 0 with 0 errors / 0 warnings (info-level style lints only). Focused chapter/replica/failure coverage passes 153/153, including the structured migration/materialization cases moved in this pass, and the complete `packages/downloads/test` suite remains 408/408.

## Fourth cut: persistent chapter service class boundary

A repository-wide large-file ranking after the durable-store cuts showed `chapter_downloads.dart` still at 3,922 lines. Unlike the remaining store nucleus, this file contained an already independent object boundary rather than one intertwined authority: `PersistentChapterDownloadService` occupied roughly 2.1k lines while contracts, the memory fallback, `PersistentDownloadComposition` and management-projection builders lived before it. Its durable-ready index and progress publisher were service-private helpers. The class did not need a new interface or runtime owner; it only needed its source responsibility to match its existing object responsibility.

`PersistentChapterDownloadService`, `_DurableReadyRecordIndex` and `_ChapterProgressPublisher` therefore moved byte-for-byte in behavior into `persistent_chapter_download_service.dart`, another `part` of the same Dart library. Shared helpers used by the memory and persistent services stay in `chapter_downloads.dart`, as does the canonical-projection monotonicity helper also consumed by the artifact-store part. No constructor, state field, method body, scheduler, lifecycle or API was redesigned.

After this extraction `chapter_downloads.dart` is 1,646 lines and `persistent_chapter_download_service.dart` is 2,279 lines; the core persistent artifact store remains 6,875 lines and structured placement 2,857 lines. Targeted analysis again exits 0 with no errors or warnings; the class only carries its pre-existing info-level style lints to the new file.

## Final stop condition for this phase

A final state-domain review of the 6,875-line core finds no second structured-like collaborator waiting to be peeled off. Its remaining mutable serialization domains are the exact artifact write/proof tail, exact artifact mutation tail, physical-partial mutation tail, physical-artifact mutation tail, replica mutation tail, redundant-partial retirement set, borrowed exact/physical spool sets, cleanup-debt drain and redundant-partial sweep. These are coupled by the same authority transitions: partial→READY promotion, exact↔physical canonicalization, replica registration/retirement, StorageRoot alias access, schema-16 cleanup debt, schema-17 promotion recovery and borrowed session spool mutation.

Replica migration remains HOLD for this exact reason. Its copy/resume/cleanup path crosses the artifact serializer, StorageRoot aliases, SAF/Direct I/O, cleanup debt and later replica read/retire authority; extracting it now would either move a large block without reducing coupling or require a wide reverse-callback interface. Partial/canonical backfill and cleanup likewise share the borrowed-spool and physical-authority serializers. There is no evidence that another runtime owner should exist.

The Downloads large-file decoupling phase is therefore complete at the responsibility level, not at an arbitrary line-count target. Future extraction should require a new independently owned state/lifecycle (for example, a real retained multi-root convergence owner if that policy is ever introduced), not merely a desire to make the 6.9k-line authority nucleus smaller. No formatter was run, and these source moves do not change SQLite schema, public API, transfer rank, NetLane, Reader windows or artifact/partial authority.
