# zic Implementation Plan

本文件只列未完成工作。

## P0：首页封面设备闭环

- 确认 `home-library-primary` 在第一条 `homeCoverRequested` 前快速完成；对比 primary/enrichment 耗时。
- 检查首页 SavedComic/ImportedChapter primary 发布后封面请求是否由约 1.88 秒降至存储主查询完成时间。
- 若 primary 仍慢，继续拆分 `library.list` 与 `listSavedComics` 的真实 SQLite query plan；不得增加第二套封面缓存。

## P0：远程 WebP 前台 producer 闭环

- 检查 `bytesCommitted.chunks` 是否由数十个 1.4 KiB transport chunk 收敛为一次实际 append。
- 检查 `downloadFlowPressure` 的 hold/release：holder depth≤1 时 hold，depth≥3 后 release；不得长期保持。
- 验证 current frame cadence、source growth 和同源背景吞吐；不得缩小 7/3 或稳定 lane 数。

## P0：Flutter 编译与 owner tests

- 运行 `flutter analyze`、sessions/home owner tests 和 App target tests。
- 验证 `BytesBuilder` 合并、flow-gate cancellation、Home primary gated-enrichment tests。

## P1：缓存身份与 Reader 回归

- 继续验证 dev.135 stable cover/artifact identity 和 dev.134 同章资源会话 retention。
