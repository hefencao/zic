# dev.120 后续交接

唯一后续基线：`zic_v0.31.0-dev.120_directed-prefetch-source-wake.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0104-directed-prefetch-source-wake.md`
9. `docs/audits/dev120-directed-prefetch-source-wake-audit.md`
10. `docs/audits/dev120-validation-results.md`

## 下一份 Trace

### 纵向静态图预加载

逐页比较 `sourceReady` 与首个 `decodeRefill sourceWake=true`、`frameDecoded`、`frameUploaded`。正常 7/3 预加载必须在页面进入视口前完成；不要重新引入 visible role。

重点检查：

- `decodeRefillSourceWakeCount`；
- source-ready→decodeRefill 延迟；
- source-ready→frame 0 延迟；
- 静态 output 的 `staticFrameKept` 与 `frame-budget` 回收；
- 滑动不足半屏时是否直接显示已预加载 output。

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
