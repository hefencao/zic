# ADR 0140：Cloudflare真实浏览器会话、详情路由与插件持久恢复

**状态：Accepted**

## 背景

dev.154 真机出现四个相互放大的问题：Cloudflare challenge 接近完成后重新开始；从 source详情首次进入并持久化后第二次点击无法进入；部分 Home阅读历史封面失败而详情封面正常；已导入插件记录消失。

## 决策

1. Cloudflare验证 WebView使用当前 Android WebView provider真实 User-Agent，不用插件/OkHttp静态 UA覆盖。Cookie、localStorage和真实 UA作为同一 browser snapshot revision保存。
2. Mihon runtime同步导入同 revision Cookie，并在 application interceptor对同站点请求逐请求采用 snapshot UA；无 snapshot时才使用插件默认 UA。
3. source页已持有 `sourceId + comicId` route lock且发现本地 SavedComic时直接 push详情，不再嵌套申请同一 identity锁。
4. Home HTTP(S) artwork locator无论 source/plugin是否 active，都先通过统一 artwork gateway做 source-independent durable-cache probe；网络 URL不得回落到本地文件 loader。
5. 外部插件 manifest逐记录解析。单条坏记录只产生诊断，不清空其它插件。写入保留上一代 `.bak`；启动按主 manifest、`.bak`、`.part`、旧 `.invalid`依次恢复，并允许旧 sandbox绝对 payload路径按当前 owned root basename迁移。
6. manifest恢复只恢复记录和 owned payload定位；激活仍执行既有 digest、signer、ABI、entry class与信任检查。

## 不采用

- 不继续调整 Cloudflare稳定完成秒数来掩盖 UA/浏览器指纹不一致。
- 不把历史网络封面放入 App私有缓存。
- 不删除 comic route lock；只修正同一调用链的嵌套所有权。
- 不因为 manifest恢复而绕过插件 payload完整性或签名检查。
