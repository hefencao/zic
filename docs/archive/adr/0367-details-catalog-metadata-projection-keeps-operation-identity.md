# ADR 0367: Details catalog metadata projection keeps operation identity

Status: Accepted

## Context

A complete ordinary Release export reports27 chapters on details refresh, while
the same details screen grows from27 to34 rows and1184 to1842 known pages.
Mihon host ordinal/parent locators changed the exact IDs of stored chapters.
The local details join knows only exact ID/unique revision, then appends the
older imported records as separate chapters. Correct6→5→6 boundary commands
still enter68/68 and1/198; this is a separate read-only details defect.

## Decision

Home details composition passes the existing plugin-host complete-model
comparison to a pure scope-bound projection. Exact catalog IDs take precedence;
fallback requires a unique complete model in the current source/comic catalog.
All URL/name/memo and other source-owned fields remain inputs. A short-lived
per-call key map only avoids repeated parsing; it is not a catalog cache.
The resulting immutable library-identity→catalog-ID map accompanies the details
snapshot. Details consumes it only for metadata and suppressing duplicate rows.
Display joins validate the actual catalog chapter's source/comic scope, rather
than the route's raw comic alias. The existing exact/revision action lookup is
unchanged; a preferred snapshot alias can differ from the original route.

Current exact/revision metadata takes precedence. Otherwise latest historical
progress and stored page count/read state/sync time can describe the current
row. A fresh exact entry without progress still displays the historical progress.
Current manual read choice precedes the latest projected historical manual
choice; automatic unread must not erase an explicit choice. Continue reading
retains the existing real history record. Library and source IDs are unchanged.

The matched display entry must never become the action entry. Open/download/
delete/read-write still use the existing exact/revision reuse and source ensure
paths; the complete-model key proves no page bytes. Whole-comic downloads,
storage migration, source catalog and Reader/Pipeline scheduling are unchanged.
UI has no plugin-host or Reader-composition dependency and performs no parsing.

## Validation and limits

The new widget regression fails before consuming the projection because the old
stored row is still appended. Nine new tests cover metadata/history, manual read,
open/download/read/delete identity, changed memo, malformed IDs, ambiguous
catalog models, exact precedence and cross-source/comic rejection.
Focused details/source-readiness/Reader composition27 tests pass.
Two intermediate count assertions were test locator/text defects and corrected
without changing production behavior. A strengthened manual-read fixture also
fails before the final precedence correction: a current automatic unread state
must not shadow the historical manual choice, but current explicit toggles win.
The prior required gate2181/Rust22 and ordinary Release1243-event refresh retain
27 source catalog chapters and one unproven historical record: the older model
omits memo while the current model contains an empty map. Six host-ID duplicates
are merged;28 details rows and1184 known pages are correct under the full-model
proof. No equality relaxation is justified to reach an assumed27-row target.
Boundary/history entry remains correct. Source review additionally found that
route admission retains the original comic while details snapshot resolves the
preferred canonical alias. Two failing-first widgets reproduce lost projected
metadata and current-entry reuse under this supported alias boundary. The
display scope now follows the actual chapter and restores the original action
lookup. The scope-inclusive full gate and ordinary Release verify this boundary.
The scope-inclusive gate2183/Rust22 and ordinary Release28ab8ee0 preserve28 rows,
history, idle slider and previous68/68→next1/198. A cold-start inspection also
shows only263 known pages: the shared details count helper rejects compact page
locators even though the Home snapshot codec explicitly retains the stored
pageCount. A real codec round-trip widget fails on missing5-page metadata while
the same compact entry correctly fails page reuse. Display now consumes this
stored count through a separate pure helper. The original count helper and its
four preview-navigation call sites remain unchanged; source pageCount still wins.
The older source-browser fixture conflated count display with locator reuse. Its
count expectation is aligned with the current metadata contract while keeping
the non-reuse and monotonic trace-clock checks. Focused78 tests pass with the
existing three quarantines. The count-inclusive required gate passes2184 tests
across27 suites plus Rust22; all three ABI/JNI checks and the minified Release
build pass. Installed ccdcfafb preserves28 rows/1184 known pages on cold open,
refresh and Reader return, with historical第6話1/198 unchanged. Its complete
6616-event export starts at t0, has no task failure, and verifies previous68/68
then next1/198; idle slider first frame arrives31.617ms after release before
content motion. Five installed Mihon main-list rows retain version and ABI.
An independent886us drag sample/velocity-12.21 remains under attribution; it
does not reopen the accepted metadata or earlier Reader contracts. Final
display, cadence and other source/Plan criteria remain separate. Evidence is
in the loading/chapter/plugin regression audit.
