# dev.111 后续交接

唯一后续基线：`zic_v0.31.0-dev.111_buffered-decode-recovery-startup-pressure.zip`。不得使用 dev.110 或更早 ZIP、旧工作树或陈旧 Android `.so`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0094-staged-decode-waterlines-last-output-retention.md`
9. `docs/adr/0095-buffered-decode-recovery-startup-near-pressure.md`
10. `docs/audits/dev111-decode-recovery-startup-pressure-audit.md`
11. `docs/audits/dev111-validation-results.md`

## 下一份 Trace

重点检查：

- startup pressure hold 期间 sourceRead priority；
- frame 0 presented 到 firstFrameReady；
- `retryScheduled stage=decode-recovery` 的 attempt/bufferedDepth；
- failure 后 buffered frame 是否继续 `framePresented`；
- lastFrameKept 与 staged refill。

## 保持边界

7/3、5/3/2、c/n/m/p/l、两个常驻 decode isolate、libwebp 帧内单线程不变；Reader/App 不拥有 retry、cache、session、lane 或 texture。
