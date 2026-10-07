# dev.137 首页封面与远程 WebP 前台流量审计

## 输入

- 唯一基线：`zic_v0.31.0-dev.136_catalog-weight-compile-cleanup.zip`
- 设备 Trace：`zic-debug-trace-2026-08-05T05-45-28.jsonl`

## 首页封面结论

封面慢点不在图片解析或持久缓存读取：

- `homeServicesReady` 约 54 ms；
- 第一条 `homeCoverRequested` 约 1,881,489 µs；
- 请求发出后，持久缓存通常约 4–14 ms 返回 source；
- source ready 到首帧通常约 27–77 ms。

真正的延迟在封面组件生成之前。`HomeLibrarySession` 原来串行执行章节、已保存漫画、分类、漫画偏好、源偏好、缺失偏好补写和全部阅读状态，直到所有 enrichment 完成才发布首页投影。

## 远程 WebP 结论

设备 Trace 中多个远程页面约 16–20 MiB，却由 source transport 输出 11,000–13,850 个小块，典型平均块约 1.4 KiB。旧路径对每个 transport chunk 都执行：

```text
DownloadSession.append
→ artifact append
→ native EncodedSource append
→ source revision/listener
```

四个同源后台预下载并行时，这些细碎写入、native ingress 和 revision 回调与 current producer 竞争。current source 未封缄且 holder 深度耗尽时会反复等待 source growth，表现为播放卡顿。

## 所有权

- 首页主数据/增强数据发布：`apps/app/HomeLibrarySession`。
- transport chunk 合并：`sessions/DownloadJob`。
- current producer 水位与同源传输让行：`sessions/LiveCoordinator`。
- 并发上限与 7/3 窗口：`pipeline_runtime/ReaderPipelineProfile`，保持不变。
- Reader UI 不拥有网络流控或正文缓存。

## 决策

1. 首页章节投影和 SavedComic 并行读取，完成后立即发布；分类、偏好、阅读状态和缺失默认值补写继续 enrichment。
2. 普通远程响应首批约 16 KiB 尽快进入 source，之后按 64 KiB 物理合并后再调用一次 `DownloadSession.append`。
3. 流错误/取消前已到达的 pending bytes 先提交，保持 partial/resume 语义不依赖 transport chunk 大小。
4. current 远程 source 未封缄时，只有在 current 启动、waitingSource 或 decode depth ≤1 时暂停同 bucket 背景任务拉取下一块；depth 补到 3 后立即恢复。
5. 不取消背景 demand，不关闭预下载，不降低 7/3、全局 5、decode 3、upload 2 或远程 bucket 5。
6. 静态图、已封缄 source、本地来源和其他 source bucket 不参与该让行。

## 拒绝方案

- 不把 1.8 秒封面延迟归因于图片解析。
- 不提高图片解码线程或新增封面缓存层。
- 不把后台预下载窗口缩成 0。
- 不让 Reader Widget 直接暂停 transport。
- 不只合并 Trace 统计而继续逐 1.4 KiB 执行实际 artifact/native append。
