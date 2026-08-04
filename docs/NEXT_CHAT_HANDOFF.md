# dev.116 后续交接

唯一后续基线：`zic_v0.31.0-dev.116_runtime-webp-classification-compile-closure.zip`。不得使用 dev.115 或更早 ZIP、旧工作树或自行重建代码。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0099-empty-artifact-self-heal-static-host-keepalive.md`
9. `docs/adr/0100-runtime-webp-classification-vertical-host-retention.md`
10. `docs/audits/dev116-runtime-webp-classification-compile-audit.md`
11. `docs/audits/dev116-validation-results.md`

## 下一份设备 Trace

重点检查：

- `mediaClassified` 的 page、animated、frameCount 与 complete；
- `runtimeStaticPages`、`assumeUnresolvedStatic` 和 static-warm decode/upload；
-纵向邻页是否在成为 current 前 `firstFrameReady`；
- `pageHostMounted.keepAlive=true`，current±4 是否不再 dispose/remount；
- `emptyArtifactEventCount` 与 `emptyArtifactHandoffStoreCount` 仍为 0；
-若页面仍无限 loading，区分 source、decode、upload、FrameBudget 和 host lifecycle。

## 不可改变

- 下载 7/3、全局 5 槽、来源 bucket 与页面 rank；
-动画 c/n/m/p 8/6/4/3、last keep；
-静态 96 MiB 选择预算、128 MiB output budget；
- cache manager 决定 tier/失效，backend 只执行存储原语；
- Reader Widget 不持有 frame、texture、cache body 或 session。
