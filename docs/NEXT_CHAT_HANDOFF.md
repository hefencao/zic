# dev.112 后续交接

唯一后续基线：`zic_v0.31.0-dev.112_ranked-download-adaptive-webp-prefix.zip`。不得使用 dev.111 或更早 ZIP、旧工作树或陈旧 Android `.so`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0094-staged-decode-waterlines-last-output-retention.md`
9. `docs/adr/0096-ranked-page-download-adaptive-webp-prefix.md`
10. `docs/audits/dev112-ranked-download-adaptive-prefix-audit.md`
11. `docs/audits/dev112-validation-results.md`

## 下一份 Trace

重点检查：

- `downloadStarted` 的 priority、bucket、globalActive、bucketActive；
- 跨页跳转后旧 Reader/旧窗口任务是否停止；
- sourceRead scheduler wait 与 first chunk；
- `decode-prefix` 的 frame/sourceLength/nextSourceLength；
- taskFailed 的 sourceSealed、requiredSourceLength、failureClass；
- staged refill、lastFrameKept 与首帧发布。

## 保持边界

7/3、staged c/n/m/p/l、decode/upload 3/2、全局 page download 5、两个常驻 decode isolate、libwebp 帧内单线程不变。Reader/App 不拥有 cache、session、lane、prefix hint 或 texture。
