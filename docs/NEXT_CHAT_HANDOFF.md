# dev.114 后续交接

唯一后续基线：`zic_v0.31.0-dev.114_vertical-visible-static-memory-preload.zip`。不得使用 dev.113 或更早 ZIP、旧工作树或自行重建代码。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0097-direct-durable-ingress-texture-lease-pool.md`
9. `docs/adr/0098-vertical-visible-demand-static-output-budget.md`
10. `docs/audits/dev114-vertical-static-demand-budget-audit.md`
11. `docs/audits/dev114-validation-results.md`

## 下一份 Trace

重点检查：

- vertical observation 中 current/target coverage 与滚动方向；
- 页面刚进入视口时的 transition decode/upload demand；
- `staticWarmDecodes`、`staticWarmUploads` 与 FrameBudget output 回收；
- pageHost mount、firstFrameReady、dispose 和 `firstFrameReady=false`；
- direct ingress、texture lease reuse、frame 0 outputPrepare 与 mount-to-first-frame。

## 保持边界

- 动画 staged c/n/m/p 8/6/4/3 与 last keep 不变；
- 下载 7/3、全局 5 槽、来源 bucket、页面 rank、decode/upload lane 和两个常驻 decode isolate 不变；
- 96 MiB 只用于静态策略选择，128 MiB FrameBudget 仍是实际 output 权威；
- Reader Widget 不拥有 decoded frame、texture、cache body 或 session。
