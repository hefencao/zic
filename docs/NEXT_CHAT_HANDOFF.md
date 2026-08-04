# dev.117 后续交接

唯一后续基线：`zic_v0.31.0-dev.117_single-frame-webp-bootstrap.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0101-single-frame-bootstrap-early-webp-classification.md`
9. `docs/audits/dev117-single-frame-webp-bootstrap-audit.md`
10. `docs/audits/dev117-validation-results.md`

## 下一份 Trace 分开采集

### 横向动态 WebP

检查 `one>0`、frame 0、`mediaClassified animated=true`、后续 staged refill 和 playback。

### 纵向静态图

检查 static-warm 页面是否按 priority 逐个出现 `one>0`，并在成为 current 前完成首帧。

## 不可改变

- 下载 7/3、全局 5 槽和来源 bucket；
- 动画 c/n/m/p 8/6/4/3；
- 静态 96 MiB 选择预算、128 MiB output budget；
- last keep；
- cache manager、DownloadSession、DecodeSession 和 texture 的现有所有权。
