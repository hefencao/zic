# dev.247 验证结果

## 候选

- Source：`0.31.0-dev.247`
- App：`0.31.0+247`
- 唯一代码基线：`zic_v0.31.0-dev.246_stable-destructive-preemption-transaction.zip`
- 真机证据：`zic-debug-trace-2026-08-12T13-06-36.jsonl`

## Trace 结论

- 共7302条事件；`downloadPreempted=21`且全部incoming priority=1000。dev.246的normal-pressure删除、100ms稳定candidate与single-flight transaction方向继续成立。
- `policyDecision`中scrolling/idle共99次，全部`downloads=11`；scrubbing共114次，全部current-only `downloads=1`。
- `mediaClassified` 4次，全部`animated=true`、`frameCount=154`。
- 可提取正文总长度42个样本，中位约15.5MiB、最大约18.7MiB；动画完整3/7 network window可能形成超过100MiB潜在encoded工作，因此dev.247优先缩network admission而不是继续提高cancel retention。

## 工作树验证

- dev.205–dev.247 history/ownership gates：43/43 PASS，最多8 workers。
- documentation responsibility：PASS；Architecture 420行、Implementation Plan 180行、Next Handoff 80行，未放宽职责预算。
- Dart structure：PASS（359 Dart files / 134 test files）。
- Pipeline runtime boundary / demand stability / Reader streaming / UI architecture / test quarantine / Android runtime dependency / texture Kotlin compile / dev.139 current-documentation：10/10 PASS。
- `tool/check.sh`仍在入口仅因唯一dev.246基线缺少 pinned `third_party/source_archives/libwebp-1.6.0.zip`停止；没有从旧包或文件库补入。
- 当前环境无 Dart/Flutter/Cargo，因此没有宣称执行 Dart/Flutter/Rust行为测试或APK build；Kotlin compile gate实际执行通过。

## 新合同静态/行为源码覆盖

- `AnimatedPrefetchPolicy`：previous2/next4硬下界、previous3/next7上界、50MiB默认预算、四级waterline expansion。
- `animated_prefetch_policy_test.dart`：逻辑RoleWindow仍11项但stage0 network只7项；水位逐层开放；下界超预算不缩；跳页stage重置、runtime static恢复11、stale revision拒绝。
- `LiveCoordinator`只在成功refill达到target watermark后回报revision-scoped milestone；Pipeline决定network expansion。
- App preference持久化与Network Settings暴露动画WebP预算，Reader factory retention key包含预算值，避免复用错误配置的retained session。
