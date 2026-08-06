# ADR 0129：封面首帧 Watchdog、详情来源就绪与媒体宽度

**状态：Accepted**

## 背景

设备 Trace 显示本地封面已从 durable cache 返回 5.9 MiB 完整字节，但后续既没有首帧也没有 decoder error。仅依赖 `Image.errorBuilder` 无法恢复这种悬挂流。另有详情页在插件 host 尚未 ready 时立即刷新并失败，以及真实章节与兼容伪章节同时显示的问题。

## 决策

1. encoded artwork source ready 后启动 2.5 秒首帧 watchdog；无帧无错误时，对同一稳定 `cover` cache identity 至多强制重读一次并重建 ImageStream。
2. 重试期间保持同一柔和占位图；不得清空全局 response cache 或 Flutter image cache。
3. 远程详情先从持久 catalog 构造页面，后台最多等待 5 秒取得 current active source；失败保留缓存内容。
4. preview/comment/章节操作在实际调用时解析 current adapter，不捕获插件重启前的 source session。
5. 实际预览行含横图最多 2 张、纯竖图最多 3 张；完整行使用全部媒体宽度。稀疏末行允许到参考面积 2.4 倍，展开高度上限 90%。
6. `AppPullToRefresh` 同时拥有刷新进度和结果图标位置。
7. 真实 Mihon 章节存在时，compatibility/synthetic 章节在所有 Presentation 边界移除。

## 非目标

- 不增加全局封面重试频率。
- 不建立详情页专用图片缓存。
- 不吞掉 `sourceVerificationRequired`。
- 不通过伪章节掩盖空目录或验证失败。
