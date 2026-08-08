# Project Rules

## Architecture and documentation

- Reader submits observations and commands and consumes read-only Pipeline output. It must not own transport, page bytes, session, cursor, decoded frame, texture, retry or prefetch state.
- `NetLane` is the only network scheduling authority. Do not add a holder-depth, playback-state or UI-owned network eligibility gate.
- Stable documentation must describe current production code, not a superseded experiment. Historical attempts belong in `CHANGELOG.md`, ADRs and `docs/audits/`.
- When ownership, lifecycle, default policy or public contracts change, update `docs/ARCHITECTURE.md`, `docs/SPEC.md`, `docs/IMPLEMENTATION_STATUS.md` and `docs/NEXT_CHAT_HANDOFF.md` in the same change.
- ADR status must be exactly Proposed, Provisional, Accepted, Superseded or Rejected. Do not use ambiguous combined status text.

## Editing and validation

- Do not run `dart format`. Make only minimal, manually formatted edits.
- Distinguish product defects from test defects. Do not restore superseded production behavior merely to satisfy an outdated test.
- 只有具有基础性、重要性、隐蔽性或长期稳定契约的代码/功能才要求新增回归测试；普通 UI 文案、一次性布局和非稳定实现无需单独新增回归测试。已有测试仍不得因该规则删除或规避真实缺陷。
- Delete code only after repository-wide production, test, export and documentation reference checks.
- Run all available repository, documentation, ownership, platform and toolchain checks. Missing Flutter/Android/Rust tools must be reported as unverified, not silently treated as passed.
