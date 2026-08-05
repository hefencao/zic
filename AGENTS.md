# Project Rules

## Baseline and reading order

- Use only the explicitly named complete ZIP as the code baseline. Do not merge an earlier worktree, patch replay tree or reconstructed candidate.
- Before editing, read in order: `AGENTS.md`, `docs/NEXT_CHAT_HANDOFF.md`, `docs/ARCHITECTURE.md`, `docs/SPEC.md`, `docs/IMPLEMENTATION_PLAN.md`, `docs/IMPLEMENTATION_STATUS.md`, then the latest relevant ADR/audit and supplied errors or Trace.
- VibeVenera, Mihon and third-party source archives are read-only references unless the user explicitly requests otherwise.

## Architecture and documentation

- Reader submits observations and commands and consumes read-only Pipeline output. It must not own transport, page bytes, session, cursor, decoded frame, texture, retry or prefetch state.
- `NetLane` is the only network scheduling authority. Do not add a holder-depth, playback-state or UI-owned network eligibility gate.
- Stable documentation must describe current production code, not a superseded experiment. Historical attempts belong in `CHANGELOG.md`, ADRs and `docs/audits/`.
- When ownership, lifecycle, default policy or public contracts change, update `docs/ARCHITECTURE.md`, `docs/SPEC.md`, `docs/IMPLEMENTATION_STATUS.md` and `docs/NEXT_CHAT_HANDOFF.md` in the same change.
- ADR status must be exactly Proposed, Provisional, Accepted, Superseded or Rejected. Do not use ambiguous combined status text.

## Editing and validation

- Do not run `dart format`. Make only minimal, manually formatted edits.
- Distinguish product defects from test defects. Do not restore superseded production behavior merely to satisfy an outdated test.
- Delete code only after repository-wide production, test, export and documentation reference checks.
- Run all available repository, documentation, ownership, platform and toolchain checks. Missing Flutter/Android/Rust tools must be reported as unverified, not silently treated as passed.

## Delivery

- Release delivery must include a complete ZIP, SHA-256 and a baseline-to-release patch generated for `git apply --index`.
- Resolve `patch_dir` from `ZIC_PATCH_DIR` or the local `.zic-workspace.json`; do not hard-code a machine-specific directory.
- `.zic-workspace.json` is machine-local and must not be included in release ZIPs or generated patches.
- Patch application instructions must use `"$(python3 tool/workspace_config.py patch_dir --absolute)/<patch-file>"` directly; do not introduce a chat-only `PATCH_DIR` variable.
