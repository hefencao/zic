# dev.121 后续交接

唯一后续基线：`zic_v0.31.0-dev.121_static-watermark-localized-reader-rebuild.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0105-static-single-frame-watermark.md`
9. `docs/audits/dev121-static-watermark-reader-rebuild-audit.md`
10. `docs/audits/dev121-validation-results.md`

## 下一份 Trace

### 混合静态/动画章节

- 权威静态页解出并呈现一帧后，不应继续产生该页的 `c>3/c>5/c>7` refill；
- 动画 current/transition 继续按 8/6/4/3 补水；
- 预加载页 source-ready 后仍应定向完成 frame 0。

### 纵向滚动

- 复验偶发回拉、settling 抖动与上下滑动稳定性；
- 使用 Flutter performance overlay/DevTools 比较 build/layout，普通 current 变化不应重建整个 ListView/Scaffold；
- 检查 page host mount/dispose、staticFrameKept 与 frame-budget 回收。

## 不可改变

- 不拆分静态/动画 refill 状态机；静态页一帧即满足，动画仍为 8/6/4/3；
- 下载窗口前 7 / 后 3；
- remote/global 并发 5，本地 bucket 2；
- decode/upload lane 3/2；
- 静态 96 MiB 选择预算与 128 MiB output budget；
- last keep；
- DownloadSession、Pipeline、FrameBudget 与 texture 的现有所有权。
