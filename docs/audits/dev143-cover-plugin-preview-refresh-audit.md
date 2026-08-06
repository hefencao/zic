# dev.143 封面、插件、预览与刷新审计

## 设备证据

- 同一组 Venera 封面出现大量 `homeCoverRequested`，只有本地封面获得 source/frame；失败封面随 Home rebuild 反复重启。
- Mihon browse/details 抛出 `sourceVerificationRequired`，底层明确为 Cloudflare verification failed。
- Venera 详情刷新在亚毫秒级以 `StateError` 失败，符合 runtime/session 生命周期短路而非网络超时。

## 代码根因

1. Home 失败状态把新建 loader closure 当作新资源，任何父级 rebuild 都立即重试。
2. source Future 与 ImageStream 各自切换 loading/placeholder 并计时重试，形成闪烁。
3. browser snapshot 在每次 Mihon/Venera HTTP 请求前重复导入，可能用旧 snapshot 覆盖 runtime 新 Cookie。
4. MethodChannel 只恢复 PlatformException，不恢复 protocol envelope 中的 retryable lifecycle error；已打开的详情页还可能继续持有插件重启前的已关闭 source adapter。
5. 预览外层 SliverPadding、内层 Card 和内层 12 px padding 重复占宽；残余宽度又被放进 item gap。旧候选预判还会生成“实际没有横图却只有两张”的行。
6. 详情使用隐形 anywhere refresh，来源页使用可见 onEdge refresh。

## 修复

见 ADR 0128。未清空全局 artwork cache，未新增第二套 CookieJar、网络调度或插件 session 所有权。
