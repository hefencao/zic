- 在完整 Android release工具链中构建 minified APK，并用 `jadx`/`dexdump`确认 `dev.zic.network.SourceVerificationRequiredException` 保持原始名称；随后在真机重新激活 Mihon共享扩展。
# zic Implementation Plan

## P0：Mihon 插件识别设备闭环

- 使用直接字符串和 `@string/...` metadata 的真实 Mihon APK分别验证 extensionLib、单入口和多入口 class解析。
- 验证插件重启时 common runtime预检不再要求内部 `AndroidBrowserCookieSession`，并确认 Cookie snapshot reset仍在首个真实 request前生效。
- 对无法识别的 APK导出 package、metadata key、ABI和 entry class诊断，不能静默表现为“未检测到”。

## P0：身份、同源更新与验证设备闭环

- 使用真实 Venera/E-Hentai successor 检查详情“有新版本”、统一比较确认和 Reader 首次提醒；确认换 successor 后再次提醒。
- 验证同源迁移只复制 exact chapter identity；sequence-only 候选不复制阅读状态或 artifact。
- 在禁漫天堂完成 WebView 验证后确认 source restart 的首个实际 request 导入最新 same-site snapshot，且不会因为浏览器页面已经正常而错误跳过 handoff。
- 使用真实章节目录检查 SavedComic、ImportedChapter 与远程详情都不再保留“开始阅读/正文”synthetic chapter。

## P0：来源投影、Cloudflare 与封面身份设备闭环

- 在 Venera/Mihon 多次切换且目标请求失败时，确认页面在同一帧切换为目标缓存或目标 loading/error，绝不显示旧 source 卡片。
- 对禁漫天堂执行强制刷新，确认只有真实 Cloudflare challenge 产生 `sourceVerificationRequired`；普通 403/timeout/解析错误保持原分类，主/兼容 interceptor 行为一致。
- 让同一漫画同时进入更新与历史，并改变 resume chapter、Home enrichment 和前后台状态；确认封面 State 不被章节 key 销毁，Trace 不再出现同 identity 同时重复 source/first-frame owner。
- 分别制造离屏未绘制、ImageStream error 和 encoded-source failure，确认 watchdog 只处理 provider stream，只有明确 decode exhaustion 才刷新 encoded bytes。

本文件只列未完成工作。

## P0：Transition 首帧与切页设备闭环

- 验证拖动建立 transition 后，即使 current holder 为 0，目标页也先产生独立首帧。
- 确认目标页网络不等待 current source sealed、完整下载或 holder depth。
- 验证 transition 首帧后 current 基础水位先于 transition 深水位，且反向拖动不重建同一 identity。

## P0：远程 Animated WebP 连续性

- 对比 transport chunk、64 KiB session append、source revision、decode batch、holder depth、deadline 和 present cadence。
- 若 current 仍断粮，只在 NetLane ranking、重复 request/source、partial wake、decode producer 或 upload deadline 内定位；不得恢复 FlowGate/startup-buffer、缩小 7/3 或降低速度。

## P0：后台重入生命周期

- 验证两分钟内同章重入命中 `readerSessionReused`，不重新创建整组 Download/Source/Decode session。
- 确认 used texture 仍重新创建，idle resource retention 不跨 Reader 复用 SurfaceProducer。
- 验证 TTL、source revision变化和第二章节淘汰后的完整 dispose。

## P0：Flutter/Android 工具链闭环

- 运行 `flutter analyze`、受影响 package owner tests、App tests和 Android debug/release build。
- 运行 Rust/Android target 与 JNI symbol验证，确认 APK 中 native build identity正确。

## P1：漫画源、过滤与详情预览设备闭环

- 真机验证 Mihon Popular/Latest 与 Venera 多 explore/category section 的顺序、分页和 section identity。
- 验证浮动搜索历史持久化；展开状态下系统返回、面板上下拖动和内容列表滚动均先收起搜索并释放焦点。
- 使用真实 Mihon 扩展验证 `getFilterList()` 中 CheckBox、TriState、Select 与 Group 子项的标签、默认值和回传值；未支持的自定义 Filter 不得阻塞普通浏览。
- 验证漫画源 cache-first/background-refresh 与数据未变化时列表、封面不闪烁；下拉达到阈值后保留现有内容执行强制来源刷新。
- 在窄屏、常见竖屏、宽屏与极端横纵比预览上确认完整行尽量占满可用宽度、折叠/展开第一行一致、完整行铺满媒体宽度、稀疏末行面积不超过参考完整行 2.4 倍、每行数量规则和屏幕高度 90% 上限同时成立。
- 制造 encoded-source Future 失败、明确 decoder 错误及 encoded source 已就绪但 ImageStream 悬挂三种状态，确认首页、漫画源卡片和详情封面无需冷启动即可恢复，且不清空其它封面缓存。

## P1：首页与缓存身份

- 设备验证本轮 primary projection 到第一封面请求的时序，并确认 native prewarm、整本
  队列 restore、外部插件 activation 不再位于 Home 首帧关键路径。
- 设备验证首页多封面快慢混合时的渐进显示：确认 `homeCoverFirstFrame` 按封面独立推进，
  不被 durable response 串行写入或其它慢封面形成全局等待。
- 验证封面 URL/token 变化仍命中 stable cover key，verified artifact alias不会污染无证据页面。
- 设备验证已有 raw durable cover hit 时的 source-independent 分流：首屏不触发插件资源
  请求；同时确认已持久化 canonical alias 的同源 raw ID 在插件未激活时只显示一张书架卡片，
  且未访问书架页不创建额外 cover loader。
