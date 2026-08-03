# dev.101 文档职责与前帧 Trace 审计

## 基线

唯一代码基线：`zic_v0.31.0-dev.100_test-quarantine-texture-schedule.zip`。

## 问题清单

### 编译/测试

- dev.100 历史门禁把当前 App build 固定为 `+100`，版本升级会产生无关失败。
- quarantine marker 固定为 `ZIC-QUARANTINE(dev.100)`，测试控制语义与交付版本耦合。
- `test_dev100_test_quarantine_texture_dispatch.py` 同时检查版本、文档、实现和交付文件名，不再是单一所有者门禁。

### 文档

- README 350 行，其中大量为逐轮 release notes 和临时实现说明。
- Architecture 1602 行，前 355 行为 dev.72–dev.100 追加层，正文后又附加多轮实现段落。
- Spec 1097 行，前 306 行为逐版本“验收规格”，把当前实现和规范混合。
- Plan 1010 行，同时保存已完成版本、历史约束和当前计划。
- Status 1600 行，保存从早期版本到 dev.100 的历史、验证和待办。
- 多份文档把当前环境缺少工具链、单份 Trace 数字和未复验推断写成稳定说明。

### 性能

新设备 Trace `zic-debug-trace-2026-08-03T08-43-07.jsonl`：

- `framePipelineTiming`：174 条；
- end-to-end p50 445,997 µs，p95 2,336,878 µs，最大 12,321,754 µs；
- present p50 114,587 µs，p95 368,572 µs；
- dominant：`platformSchedule` 91、native decode 38、channel dispatch 27；
- persistent artifact 完整 stream 28 次，p50 923,147 µs，p95 2,807,553 µs；
- current decode failure 1 次。

旧 `platformScheduleMicros` 包含 platform-thread queue 和实际 `scheduleFrame()` 调用，不能据此认定 API 本身耗时。

## 所有权清单

| 内容 | 正确所有者 |
|---|---|
| 项目入口和命令 | README |
| 长期目标 | Project Charter |
| 稳定所有权/依赖/生命周期 | Architecture |
| 产品与工程合同 | Spec |
| 未完成工作 | Implementation Plan |
| 当前源码与验证等级 | Implementation Status |
| 下一轮唯一入口 | Handoff |
| 技术决策 | ADR |
| 版本历史 | CHANGELOG |
| 单轮 Trace、错误报告和验证证据 | audits |
| quarantine allow-list | repository tooling + `docs/testing` |
| schedule queue/call timing | `texture_bridge` |
| 跨阶段 dominant 归因 | `sessions` + trace analyzer |

## 被否决方案清单

- 不把旧稳定文档整体复制到 `docs/history`。
- 不再通过“最新 dev 段落覆盖旧段落”维持 Architecture/Spec。
- 不把单份设备 Trace 统计提升为跨设备性能规格。
- 不删除仍有回归价值的 quarantine 测试；改用稳定 ID 和解除条件。
- 不把 schedule 的整段 latch 等待继续归因给 `scheduleFrame()` API。
- 不因 source stream 慢直接缩小 7/3 或 2/1 窗口。

## 实施

- 重写 README、Architecture、Spec、Plan、Status 和 Handoff。
- 新增 `DOCUMENTATION_POLICY.md` 和 `check_documentation.py`。
- quarantine marker 迁移为 `Q-001` 至 `Q-003`。
- 删除版本耦合的 dev.100 聚合门禁，新增稳定 quarantine/timing contract gate。
- 历史 feature gates 不再断言当前 App build 或当前 Handoff 必须引用历史 audit。
- Android schedule timing 拆分为 queue、call 和兼容 total。
- analyzer 对旧 Trace 使用 `platformScheduleLegacy`，对新 Trace分别归因 queue/call。

## Trace 归因修正

使用 dev.101 analyzer 重新读取同一 Trace 后，旧字段的 91 条 `platformSchedule` 统一标记为 `platformScheduleLegacy`。该字段只证明 latch 区间较长，不能区分 platform-thread 排队和 `scheduleFrame()` 调用本身。只有采集 dev.101 的 queue/call 拆分字段后，才允许继续归因。
