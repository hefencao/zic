# dev.151 验证后 runtime source 替换审计

## 现象

Cloudflare验证完成并返回漫画源页后，自动刷新抛出：

```text
Bad state: external plugin runtime session is closed
ExternalPluginRuntimeSession._invoke
_RuntimeBrowsableComicSource._browse
CachedBrowsableComicSource.refreshBrowsePage
_ComicSourcesPageState._recoverSourceAccess
```

## 根因

- WebView回调通过 `restartSource` 关闭旧 runtime session并发布同 source ID的新 adapter。
- `_recoverSourceAccess` 返回后立即调用 `_reload`。
- 漫画源页的 `_activeSource` 仅从尚未完成父级重建的 `widget.sources` 中取旧 adapter。
- Catalog decorator正确调用其底层 source，因此错误最终在旧 session `_invoke` 边界暴露。

## 修改

- `ComicSourcesPage` 接入 composition source resolver。
- `_activeSource` 优先解析当前 source ID。
- WebView返回后确认 replacement adapter，并在新 adapter上重载 section/filter与 browse。
- source实例替换即使 ID列表不变，也触发新请求代次。
- 新增 Widget owner test：回调只替换 resolver所指 source，不重建 `sources`参数；恢复仍必须由新 source完成。

## 未采用

- 不让已关闭 session静默复活。
- 不在 `CachedBrowsableComicSource` 捕获该错误并返回旧缓存。
- 不通过固定延时等待 Widget rebuild。
