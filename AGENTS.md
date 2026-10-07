# Project Rules

## Architecture and documentation

- Reader submits observations and commands and consumes read-only Pipeline output. It must not own transport, page bytes, session, cursor, decoded frame, texture, retry or prefetch state.
- `NetLane` is the only network scheduling authority. Do not add a holder-depth, playback-state or UI-owned network eligibility gate.
- Scheduler cancellation/priority MUST remain observable through Reader page transport, source request-plan and runtime invocation boundaries; adapters must not replace it with an independent FIFO or release capacity before cancelled work actually exits.
- Native encoded-byte ingress MUST NOT wait on a source lock held across frame decode/scale/composite work; keep source-lock critical sections limited to byte/demux preparation.
- Stable documentation must describe current production code, not a superseded experiment. Historical attempts belong in `CHANGELOG.md`, ADRs and `docs/audits/`.
- When ownership, lifecycle, default policy or public contracts change, update `docs/ARCHITECTURE.md`, `docs/SPEC.md`, `docs/IMPLEMENTATION_STATUS.md` and `docs/NEXT_CHAT_HANDOFF.md` in the same change.
- ADR status must be exactly Proposed, Provisional, Accepted, Superseded or Rejected. Do not use ambiguous combined status text.

## Editing and validation

- Do not run `dart format`. Make only minimal, manually formatted edits.
- Distinguish product defects from test defects. Do not restore superseded production behavior merely to satisfy an outdated test.
- 只有具有基础性、重要性、隐蔽性或长期稳定契约的代码/功能才要求新增回归测试；普通 UI 文案、一次性布局和非稳定实现无需单独新增回归测试。已有测试仍不得因该规则删除或规避真实缺陷。
- Delete code only after repository-wide production, test, export and documentation reference checks.
- Run all available repository, documentation, ownership, platform and toolchain checks. Missing Flutter/Android/Rust tools must be reported as unverified, not silently treated as passed.

## Device and visual subagent

- 真机测试、设备截图/trace采集或视觉核验时，触发并复用一个固定的 `device_visual` 子代理，指定 `gpt-5.6-luna`、reasoning effort `high`；其他工作不因此委派。
- 子代理只执行主代理给出的验收步骤并汇报观察结果；代码根因、修改边界、生产代码、状态 JSON 和提交由主代理负责。同一设备只允许一个执行者，避免并行 ADB 操作。
- 设备代理执行前读取可用的 `android-ui-test` skill；缺失时按当前 UIAutomator XML 的精确标签/可点击节点定位，点击后确认实际结果，不沿用猜测坐标。误入相邻入口属于测试操作错误，不能据此修改产品。
- 非动态页面 XML 可按页面覆盖缓存到已有私有测试目录；布局/版本、滚动、密度/方向、键盘或弹窗变化后必须刷新。动态列表与 Reader 不复用旧坐标；不新增逐轮 XML 或仓库审计文件。
- 返回简短的通过/失败/未验结论、复现步骤和必要截图或 trace 路径。优先更新已有文件，不新增逐轮审计、安装快照或哈希清单。
- 若当前工具不支持指定型号或 effort，明确报告限制，由主代理继续已授权工作；不得静默替换型号，也不得把未运行的代理报告为已启用。
