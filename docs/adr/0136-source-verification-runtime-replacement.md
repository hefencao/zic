# ADR 0136：验证恢复后的 runtime source 替换

**状态：Accepted**

## 背景

漫画源强制刷新返回 `sourceVerificationRequired` 后，页面打开 WebView。浏览器验证回调会重启对应 Mihon/Venera runtime并关闭旧 `ExternalPluginRuntimeSession`。原漫画源页随后直接调用 `_reload()`，而 `_activeSource` 只从当前 Widget 的 `sources` 参数取值；父页面虽然已经发布新 adapter，子 Widget可能尚未完成下一帧重建，因此重试仍落到旧 `_RuntimeBrowsableComicSource`，抛出 `Bad state: external plugin runtime session is closed`。

详情页已有稳定 source ID resolver，漫画源页缺少相同生命周期边界。

## 决策

1. `ComicSourcesPage` 只持有稳定 `activeSourceId` 与浏览请求状态，并可由 composition root 注入 `resolveSource(sourceId)`。
2. 每次 section、filter、browse、验证恢复操作先通过 resolver取得当前 active adapter；Widget 参数列表仅作为没有 resolver时的普通来源 fallback。
3. WebView验证回调完成后，恢复流程先确认同 source ID的 active replacement存在，再在 replacement上重新加载 section/filter并执行一次强制 browse刷新。
4. 恢复后的 browse继续设置 `allowVerificationFallback=false`，同一次恢复不得再次自动打开 WebView。
5. source ID不变但 adapter实例改变时，`didUpdateWidget` 必须取消旧请求代次并重新加载来源能力。
6. 旧 session关闭后抛错是正确防护；不得让旧 adapter代理到新 session，也不得从 Catalog缓存层隐藏生命周期错误。

## 后果

- WebView验证后不再调用已关闭 runtime session。
- 页面仍可保留相同 source ID、section、query、filter和缓存投影。
- runtime adapter的创建、关闭和替换继续属于插件 composition/controller；页面只解析当前引用。
