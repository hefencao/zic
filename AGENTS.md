# Project Rules

## Architecture and documentation

- Reader submits observations and commands and consumes read-only Pipeline output. It must not own transport, page bytes, session, cursor, decoded frame, texture, retry or prefetch state.
- `NetLane` is the only network scheduling authority. Do not add a holder-depth, playback-state or UI-owned network eligibility gate.
- Scheduler cancellation/priority MUST remain observable through Reader page transport, source request-plan and runtime invocation boundaries; adapters must not replace it with an independent FIFO or release capacity before cancelled work actually exits.
- Native encoded-byte ingress MUST NOT wait on a source lock held across frame decode/scale/composite work; keep source-lock critical sections limited to byte/demux preparation.
- Stable documentation must describe current production code, not a superseded experiment. Historical attempts belong in `CHANGELOG.md`; existing ADRs and audits are archived under `docs/archive/` and read only when tracing a specific decision.
- 当前有效状态只更新 `docs/IMPLEMENTATION_STATE.json`，覆盖结论、最新验证与剩余验收；暂不新增 ADR/audit 或逐轮证据文件，不累积历史子对象。
- 编辑稳定文档前核对父标题、production owner 和同主题既有段落；按组件职责归类，不能只凭邻近关键词插入。
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
- 用户已确认当前设备自动锁屏会吞首次模拟触摸，ADB保持亮屏不代表已解锁；现已设为永不自动锁屏。导航无效先核对屏幕/Keyguard及前台页，刷新XML复核同一唯一可用目标；确认解锁后可重试一次导航并确认页面变化，不能仅据首次无效报告产品/输入故障或新增测试通路。
- 非动态页面 XML 可按页面覆盖缓存到已有私有测试目录；布局/版本、滚动、密度/方向、键盘或弹窗变化后必须刷新。动态列表与 Reader 不复用旧坐标；不新增逐轮 XML 或仓库审计文件。
- 返回简短的通过/失败/未验结论、复现步骤和必要截图或 trace 路径。优先更新已有文件，不新增逐轮审计、安装快照或哈希清单。
- 测试文件按必要性保留：原始报障输入和开放问题所需的最小复现文件可保留；验收完成后保留结论，删除不再服务开放问题的原始采集文件。重复 trace、过期截图/XML/APK、已完成备份及临时工作树及时删除，私有缓存执行同一规则。临时目录在成功或失败退出时清理，当前页面 XML/结果按用途覆盖；不得把整批文件搬到私有目录当作清理。
- 共享临时目录只删除本任务明确创建的完整路径；审查旧产物时先核对用途与消费者，不得用宽泛测试前缀 glob 批删。
- 若当前工具不支持指定型号或 effort，明确报告限制，由主代理继续已授权工作；不得静默替换型号，也不得把未运行的代理报告为已启用。
