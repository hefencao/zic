# dev.113 后续交接

唯一后续基线：`zic_v0.31.0-dev.113_texture-pool-direct-artifact-ingress.zip`。不得使用 dev.112 或更早 ZIP、旧工作树或自行重建代码。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0096-ranked-page-download-adaptive-webp-prefix.md`
9. `docs/adr/0097-direct-durable-ingress-texture-lease-pool.md`
10. `docs/audits/dev113-direct-cache-texture-pool-audit.md`
11. `docs/audits/dev113-validation-results.md`

## 下一份 Trace

重点检查：

- `bytesCommitted.cacheResident`、native ingress 与 `artifactWriteMicros`；
- `textureLeaseReused`、frame 0 `outputPrepareMicros` 与 Surface reconfigure；
- mount-to-first-frame 和首次/重进差异；
- sourceRead stream/scheduler wait；
-逐帧 timing 与 decodeRefill 比例；
- waitingSource 是否只随 source revision 推进。

## 保持边界

7/3、全局下载 5、来源 bucket、页面 rank、staged c/n/m/p/l、decode/upload 3/2、两个常驻 decode isolate和 libwebp 帧内单线程不变。Reader/App 不拥有 cache body、session、Ingress、texture pool 或 lease。
