# ADR 0303：Reader progress durable exit barrier

## 状态

Accepted

## 背景

ADR 0142 为了避免 Reader 翻页触发 SQLite 写放大，将 `ReadingProgress` 改为 storage isolate 内 latest-wins batching：普通页面变化只 enqueue，空闲约 8 秒提交，持续活跃最多约 30 秒提交。这个方向本身正确，但它同时把“Reader 正常返回也不等待 durable commit”写成生产约束。

真机回归暴露了这条约束的副作用：`reader_runtime._flushProgressBeforePop()` 只能等待 App progress callback 返回，而 production callback `_enqueueReaderProgress()` 在 `ReaderProgressCheckpointStore` 上仅执行 `enqueueProgress()` 后立即完成。也就是说所谓 flush 只到达 isolate 消息队列，不等于 SQLite commit。Home 在 route 返回后又用 route-local progress更新内存 projection，因此当前 UI 有时看起来正确，但一旦 Home/repository 重读、App lifecycle切换或测试立即检查 durable history，就会重新看到旧进度。

## 决策

普通页面变化继续只 enqueue，不恢复逐页 durable transaction。`ReaderProgressCheckpointStore` 新增 `flushProgressCheckpoints()`；production `SqliteImportedLibraryStore` 将它映射到 `SqliteProgressWriter.flush()`。SendPort 顺序保证这个 barrier 位于此前所有 `save` 消息之后，writer 在回复 barrier 前提交当前 latest-wins buffer。

Reader 正常 pop 的顺序固定为：

1. 强制采样当前最终 `ReadingProgress`；
2. drain Reader-local pending progress writer；
3. await `flushProgressCheckpoints()`；
4. 才允许 route pop；
5. route 返回后只用 route-local final progress更新 Home/详情 projection，不做整库 reload。

App lifecycle 进入 inactive/paused/detached 时执行同一 checkpoint + durable flush，但不阻塞普通页面变化。若 durable flush 自身失败，Reader可以记录错误并退出，不能为了数据写失败永久困住用户；同时不得把失败的 barrier 声称为 durable success。

这项决策只 supersede ADR 0142 “Reader route完成不等待 SQLite durability”的部分；ADR 0142 的 latest-wins batching、避免逐页 transaction 与 Home 不做整库 reload 仍保持有效。

## 验证

- Reader 控件回归必须证明最终 progress callback完成后，如果 durable flush仍 pending，route 仍不能 pop；flush完成后才退出。
- persistent storage 回归必须在 background writer 已启动后 enqueue 新进度，await flush，然后由另一 SQLite connection 立即读到最新 page。
- 普通页码变化仍不得直接调用 `saveProgress()` 或每页等待 SQLite。
