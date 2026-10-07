# ADR 0147：Home 投影、Artwork revision 与 Runtime service generation 所有权

- 状态：Accepted
- 版本：0.31.0-dev.164
- 取代：ADR 0142/0146 中与本 ADR 冲突的 Home route 刷新描述，以及 dev.163 初次 activation 由 Dart 层重放的临时实现

## 背景

dev.163 的设备 trace 暴露出三个看似独立、实际都属于“同一事实存在两个 owner”的问题：

1. 详情/章节 materialize 直接写 `ImportedLibraryStore`，而 Home 显示的是 `HomeLibrarySession` 缓存投影。新章节可以在 session 尚未看到它时直接进入 Reader；Reader 返回后 final progress 找不到 entry，只能等详情页或其它动作触发全量 reload。
2. `ComicSourceResourceGateway` 已拥有 external artwork 的基础 cache revision，但 Home/详情又把同一个 schema revision显式传回 gateway，形成 `artwork-v2:artwork-v2`；漫画源 browse 使用 gateway 默认 revision `artwork-v2`，因此同一 canonical cover 被切成两个 durable namespace。
3. dev.163 在 Dart MethodChannel backend 捕获初次 activation 的 `runtime-service-died/disconnected` 后再次调用 activation。它缓解了症状，但把 Binder service-generation 生命周期提升成了插件激活策略。

## 决策

### 1. `HomeLibrarySession` 是已挂载 Home 的 write-through projection owner

凡是会改变 Home 可见 chapter/SavedComic 集合的 App composition 操作，必须通过 `HomeLibrarySession` 完成 durable write 与内存投影更新：

- `upsertChapter/removeChapter`
- `upsertSavedComic/removeSavedComic`
- 非 Reader 批处理场景的 `persistProgress`

`ImportedLibraryStore` 继续是 durable storage owner；session 不复制持久化算法，只负责让同一成功写入立即具有一个 Home 投影结果。不得先直接写 store，再依赖后续 `_reloadLibrary()` 把状态“追上”。

Reader page callback 仍只 enqueue checkpoint。每次 Reader route 在 composition 中持有自己的 `latestProgress`，route 返回后只调用一次 `HomeLibrarySession.replaceProgress`；不得使用 `_latestReaderProgress` 这类跨 route 全局槽，也不得因 Reader 返回读取/重建整库。

`HomeLibrarySession.reload()` 读取 durable snapshot 时记录 projection revision。若 enrichment 期间发生 write-through chapter/saved/progress 更新，旧 reload snapshot不得在结束阶段覆盖更晚的 mounted projection；download snapshot刷新同样以最终可见 entries 为准。这样 reload与实时写入只存在一个单调的可见状态演进方向。

Chapter identity 仍是 `sourceId + chapterId`。`replaceProgress` 用该 identity 定位 entry；若 incoming progress 的 raw comic locator 与 entry 不同，visible projection 采用 entry 当前 raw locator归一化，不把 mutable raw alias升级为 chapter identity。

### 2. Artwork cache schema revision 只有一个 owner

`resource_cache` 暴露 `comicArtworkCacheSchemaRevision`，作为所有 comic artwork durable cache key 的 schema revision。

`ComicSourceResourceGateway` 对 external artwork 始终自己添加该 schema revision；其可选参数改为 `contentRevision`，只表示来源/内容版本。调用方不得把 schema revision当作 content revision再次传入。

因此：

```text
browse/details/history external artwork
  -> gateway
  -> revision = artwork-v2[:contentRevision]
```

同一 `sourceId + canonicalComicId + resourceRole` 在 browse、details、history 中必须落入同一个 namespace。local artwork 不经过 external gateway，但直接使用同一个 `comicArtworkCacheSchemaRevision` 构造 `ResourceCacheManager` key。

不增加旧 namespace copy、双读 fallback 或 presentation retry。旧错误 namespace 自然失效；新请求只写权威 namespace。

### 3. Binder generation 连续性属于 Android runtime-service client

`PluginRuntimeServiceClient` 负责 Binder binding generation。若 service 在**初次 activation 请求尚未完成、session 尚未建立**时发生 `runtime-service-died` 或 `runtime-service-disconnected`，client 可以把原 activation payload 保留跨越一个新的 service generation。

约束：

- 仅 `activateMihonRuntime/activateVeneraRuntime`；
- 仅 service died/disconnected；
- 每个 pending activation 最多跨一个 generation；
- established-session invocation 不保留，由既有 Dart session recovery处理；
- `runtime-request-invalid`、插件脚本异常、ABI/身份失败等 response/business error 不重放；
- bind unavailable/null binding 不当成可重放 plugin activation。

Dart `_activatePlatformRuntime` 恢复为一次 MethodChannel 调用，不再拥有初次 activation retry策略。

## 结果

- Reader 返回后的 Home history 不依赖详情页 reload。
- browse 成功写入的 canonical cover 可以被 details/history直接命中。
- Venera/Mihon 初次 activation 的 transport continuity位于实际 Binder owner，而不是插件层补丁。
- 没有新增第二 cache、第二 progress store、第二插件 session owner或 presentation retry。
