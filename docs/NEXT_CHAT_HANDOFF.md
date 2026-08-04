# dev.118 后续交接

唯一后续基线：`zic_v0.31.0-dev.118_local-direct-ingress-visible-output.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0102-local-immutable-ingress-all-visible-output.md`
9. `docs/audits/dev118-local-direct-visible-output-audit.md`
10. `docs/audits/dev118-validation-results.md`

## 下一份 Trace

### 本地动态 WebP

检查 local bucket active≤2、`artifactWriteMicros=0`、首帧和跳页 source wait；本地读取不应显示下载进度。

### 纵向静态图

检查 `readerObservation.visibleIndexes`、`policyDecision.visibleUploads`，以及可见页是否仍因 `demand-detached` 释放 output。

## 不可改变

- 下载窗口前 7 / 后 3；
- remote/global 并发 5；
- decode/upload lane 3/2；
- 动画 c/n/m/p 8/6/4/3；
- 静态 96 MiB 选择预算与 128 MiB output budget；
- last keep；
- DownloadSession、Pipeline、FrameBudget 与 texture 的现有所有权。
