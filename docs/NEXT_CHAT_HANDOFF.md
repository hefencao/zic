# dev.115 后续交接

唯一后续基线：`zic_v0.31.0-dev.115_empty-artifact-self-heal-static-host-keepalive.zip`。不得使用 dev.114 或更早 ZIP、旧工作树或自行重建代码。

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
10. `docs/adr/0099-empty-artifact-self-heal-static-host-keepalive.md`
11. `docs/audits/dev115-empty-artifact-static-host-audit.md`
12. `docs/audits/dev115-validation-results.md`

## 下一份 Trace

重点检查：

- `emptyArtifactEventCount` 和 `emptyArtifactHandoffStoreCount` 必须为 0；
-历史空条目是否失效并出现 origin fallback、正常 bytesCommitted 和 firstFrameReady；
- `skip-cache-resident` / `skip-empty` handoff；
-纵向静态 current±4 的 pageHost 是否保持 mounted；
-顶部重载发生时是 host remount、output eviction 还是 source failure。

## 保持边界

- 动画 staged c/n/m/p 8/6/4/3、last keep、下载 7/3、全局 5 槽与来源 bucket 不变；
-静态 96 MiB 只用于策略选择，128 MiB FrameBudget 仍是 output 权威；
- cache manager 负责 tier/失效，backend 只负责存储原语；
- Reader Widget 不持有 frame、texture、cache body 或 session。
