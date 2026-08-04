# dev.119 后续交接

唯一后续基线：`zic_v0.31.0-dev.119_prefetch-wake-static-output-retention.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0103-prefetch-source-wake-static-output-retention.md`
9. `docs/audits/dev119-prefetch-wake-static-retention-audit.md`
10. `docs/audits/dev119-validation-results.md`

## 下一份 Trace

### 纵向静态图

检查 sourceReady→decodeRefill/frameDecoded 的延迟、`staticFrameKept`、`frame-budget` 回收、page host dispose，以及滑入前是否已经有 output。不要重新引入 visible role；正常 7/3 预加载必须自行完成。

### 本地动态 WebP

继续检查 local bucket active≤2、`artifactWriteMicros=0`、首帧和跳页 source wait；本地读取不应显示下载进度。

## 不可改变

- 下载窗口前 7 / 后 3；
- remote/global 并发 5，本地 bucket 2；
- decode/upload lane 3/2；
- 动画 c/n/m/p 8/6/4/3；
- 静态 96 MiB 选择预算与 128 MiB output budget；
- last keep；
- DownloadSession、Pipeline、FrameBudget 与 texture 的现有所有权。
