# dev.157 根因与 owner 收口审计

## Reader

逆向链确认 dev.156 虽把 SQLite移到 isolate，但仍持续提交事务，并在 Reader 返回后的页面层刷新整库。dev.157 把 checkpoint enqueue、durable batching、Home/详情 projection彻底分成三个时序平面。

## Mihon chapter

dev.156 的 combined-first路径会把 `getMangaUpdate(...).chapters` 的空/单项结果提前当成完整目录，并阻断过去正常工作的 `fetchChapterList`。后续草案若同时调用两套接口又会造成重复网络。dev.157 固定为 explicit chapterList优先；combined只在能力不存在时调用一次。生产代码无 synthetic chapter和标题启发式。完全相同非空 `SChapter.url` 才按 source locator折叠。

## Artwork

dev.156 durable key虽已 canonical，但 Home/详情/漫画源仍残留 raw presentation key、短时 Future join、first-frame watchdog和 widget retry/evict，导致统一缓存上方仍有多个恢复 owner。dev.157 删除 presentation恢复层并把 Home/书架/详情 State统一到 canonical identity。

## 删除项

- Reader route durable `flushProgress`协议；
- post-Reader full-library reload；
- Home短时 cover source Future join；
- artwork timer/lifecycle/first-frame retry；
- presentation ImageCache eviction；
- Mihon synthetic/title chapter路径。
