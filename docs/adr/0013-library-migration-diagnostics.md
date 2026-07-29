# ADR 0013: Retained library migration diagnostics

- Status: Accepted
- Version: `0.26.0-dev.30`

## Context

Schema 5 deliberately retained ambiguity and orphan evidence in `library_migration_issue`, but the
records were only reachable through the Store API. Silently hiding them prevents users and developers
from understanding how a legacy record was assigned. Automatically deleting or re-running the
assignment would be more dangerous because the source evidence may no longer be reproducible.

## Decision

SQLite schema 6 adds nullable `acknowledged_us` to each migration issue. `ImportedLibraryStore` can
list pending issues or all retained issues and can set an acknowledgement time for explicit issue IDs.
Acknowledgement is idempotent and does not alter the issue payload, resolved source, library records or
migration decision.

The App provides one diagnostics screen that displays selectable details, copies a versioned JSON
export, filters acknowledged records and acknowledges one or all pending issues. It depends on the
Store boundary and never reads SQLite directly.

## Consequences

- Migration evidence remains durable and auditable after the warning is dismissed.
- Users can clear repeated warnings without deleting uncertain data.
- A later export-to-file/share action can reuse the same JSON schema.
- Reassigning a legacy record remains an explicit future repair workflow, not an acknowledgement side
  effect.
