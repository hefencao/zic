# dev.84 静态正文转译、Mihon 目录与详情投影审计

## 基线与范围

- 唯一代码基线：`zic_v0.31.0-dev.83_stable-preload-adaptive-pixel-stitch`。
- `mihon-main(1)` 与 `vibevenera-master(3)` 仅只读参考。
- 本轮不改变 Reader 7/3 下载窗口、2/1 预解码窗口、current/transition 上传、5/3/2 lane，也不新增 App 私有缓存或第二条 Reader 解码链。

## 问题清单

### 编译错误

1. 当前用户工具链已越过 dev.83 的编译闭包；本轮未收到新的生产编译错误。
2. `decode_target_test` 仍把“不放大小图”的产品契约错误地期望成 1080 像素，实际统一栅格输出为源宽 1024。
3. `reader_download_progress_test` 在完成 artifact 恢复场景中等待 10 分钟，说明测试仍依赖无法结束的 Widget/stream 生命周期，而不是可控状态投影。

### 产品错误

1. JMComic/18comic 静态 WebP 被分割成错位横条。截图不是动画帧问题；正文是单帧 WebP。dev.81 将 Mihon 普通正文改为宿主直连后绕过了扩展 `HttpSource.client` 的自定义 interceptor/response transform，破坏了 JMComic 的反混淆转译。
2. JMComic 章节列表再次失败。当前宿主已经调用 `getMangaUpdate`，却又无条件调用独立 `getChapterList/fetchChapterList`，重复触发同一非幂等源操作，并丢弃 `SMangaUpdate.chapters` 的权威结果。
3. Mihon 详情页显示数字 source identity，而非可读漫画源名称。
4. Mihon `SManga.genre/getGenres()` 未转译进 ZIC comic metadata，详情页无法展示 tags，自适应也拿不到真实标签。
5. Mihon 详情 description 可能因组合更新结果未被正确采用而为空。
6. 已下载/已打开章节已有真实页面列表，但刷新后的 Mihon opaque chapter token 可能因目录顺序变化而不同；章节行只按 token 查找，无法复用相同 source revision 的持久 page list，因而继续显示“页数待加载”。
7. “下载整本”使用独立 FilledButton，与喜欢/加入书架/收藏按钮风格和命令布局不一致。
8. 阅读进度仅为普通文本，缺少用户要求的“继续”药丸投影。
9. tags 没有一行折叠/点击展开投影。

### 性能问题

1. `getMangaUpdate` 后再次请求章节列表造成重复插件调用、重复网络/解析和更高失败概率。
2. 若对所有 Mihon 来源一律回退完整字节 RPC，会恢复 JMComic 正确性但全面破坏宿主流式正文；必须只对确有扩展自定义 transport transform 的来源启用 runtime transform。
3. 详情页不得为获得未知页数重新遍历并加载所有章节正文；只使用 catalog 已知值和已持久化 manifest/page list。

### 测试错误

1. `decode_target_test` 将 viewport 宽度误当强制放大目标，违背统一栅格“不放大小图”。
2. `reader_download_progress_test` 通过 Widget 全生命周期等待验证低层状态，发生 10 分钟超时；应改为可控 snapshot/stream，断言 completed/restored 状态从第一帧起不投影网络进度。
3. 新增测试不得使用真实 socket、固定等待、`pumpAndSettle`、lazy child 数量、魔法像素或精确 double 相等。

## 所有权清单

| 状态/资源/命令/生命周期 | 当前所有者 | 正确所有者 | 本轮动作 |
|---|---|---|---|
| Mihon `SMangaUpdate` 与章节列表调用 | `plugin_host_bridge/MihonRuntimeDriver` | 同左 | 采用组合更新中的 chapters；仅在能力缺失/空结果时兼容回退，不重复调用 |
| Mihon source client interceptor/正文转译能力 | Mihon extension `HttpSource.client`，但 dev.81 被宿主直连绕过 | `plugin_host_bridge` 识别能力，`plugin_host` 形成 request plan；需 transform 时仍由隔离 runtime 执行 | 按来源原子标记 `requiresRuntimeTransform`，仅 transformed source 走 runtime bytes |
| 普通图片宿主流式 transport | `downloads/pipeline` | 同左 | 对无自定义 transform 的来源保持宿主流式 |
| 漫画 source 可读名称 | `catalog SourceDescriptor`，由 bridge 生成 | `plugin_host_bridge` 翻译，App 只投影 | bridge 规范化数字/空名称；App 仅防御性 fallback |
| Mihon description/tags/status | extension `SManga` 原始字段 | bridge 翻译为 domain/catalog metadata | 读取 `getGenres/genre`，持久化并投影 |
| Comic tags identity/value | 目前未进入 `domain Comic`/`SourceComicSummary` | `domain` 值对象 + `catalog` 持久化 | 增加不可变 tags，完成协议和持久化迁移 |
| 已知章节页数 | `downloads/catalog` 中持久 manifest/page list | 详情 Presentation 只读投影 | 先按 chapter token，未命中时按同 source/comic 的唯一 source revision 关联持久 entry；不加载正文 |
| 下载整本命令 | details 页面调用已有 facade | 原 facade；Header 只发命令 | 仅统一按钮投影，不复制下载算法 |
| 阅读进度 | library/read-history 投影 | details Header 只读投影 | 显示“继续”药丸，不新增第二进度源 |
| tag 展开状态 | details Presentation 局部状态 | details Presentation | 一行折叠、点击展开；不影响 metadata owner |
| decode target 栅格 | `pipeline/domain DecodeTarget` | 同左 | 修正错误测试，不改变产品逻辑 |
| restored progress projection | `reader_runtime` | 同左 | 将测试迁到可控 owner 状态，不让 Widget teardown 决定结果 |

## 被否决方案清单

1. **继续把静态条带错乱归因于 Animated WebP source-grid 合成**：截图和 Trace 表明问题正文为单帧 WebP；该判断已被事实否决。
2. **对所有 Mihon 正文关闭宿主流式并完整 RPC 返回 bytes**：会恢复部分扩展 interceptor，却让所有普通来源退化；只允许按明确 transform capability 选择。
3. **在 App/Reader 实现 JMComic 专用反混淆**：插件内部算法和网站规则不属于 App；必须尊重 Mihon source client interceptor。
4. **`getMangaUpdate` 后仍总是调用独立章节接口**：重复调用已证明会增加非幂等插件失败；组合结果非空时必须权威采用。
5. **为了页数加载而后台遍历所有章节正文**：此前已造成章节入场延迟并被否决；只投影已知/持久化页数，未知保持未知。
6. **把数字 source id 直接暴露为显示名称**：identity 不等于用户可读名称。
7. **为 tags 在 App 建立第二份 metadata store**：tags 必须进入 domain/catalog 现有 metadata 生命周期。
8. **为了测试通过放大小图到 viewport**：违背统一栅格和原图比例契约；应修正测试。
9. **用更长 timeout、固定 pump 或 `pumpAndSettle` 修复 10 分钟测试**：只会掩盖生命周期错误；测试必须使用可控状态完成。


## 实施结果

1. 采用 Mihon 1.6 `SMangaUpdate` 的 manga 与 chapters 作为组合目录结果；仅在组合结果无章节时兼容旧 API。
2. `imageRequest(Page)` 仍负责 URL/headers；存在扩展 classloader 网络能力的 source 标记 runtime transform，由 source client 取得正确静态正文；transport 版本写入 source revision，旧未转译 artifact 自动失效。
3. source 名称、description、genres/tags 完成 bridge → domain → catalog → details 的单向迁移。
4. 已持久 page list 先按 chapter token 关联，token 刷新未命中时按唯一 source revision 关联；若 transport revision 改变，页数仍可投影，但打开章节会刷新 entry 并替换旧 artifact identity，不增加 page-list 预取。
5. 修正 decode target 错误期望，并把 restored progress 测试改为纯 snapshot。

## 验证记录

- dev.75–dev.84 所有权门禁通过。
- Pipeline/Reader/UI/Android/Mihon/Venera/外部源静态契约通过。
- Mihon payload Context 全文件 Kotlin 编译通过。
- 当前环境缺少 Flutter/Dart/Gradle，因此 analyzer、真实 Flutter tests 与 Android 构建仍未验证。


## 最终交付复验

- 工作树与系统 `unzip` 解压副本均通过仓库结构、directive、Pipeline compile boundary、dev.75–dev.84、Reader/Pipeline/UI、Android、Mihon、Venera、外部源与 native header 契约。
- Mihon payload Context 全文件 Kotlin 编译、章节组合目录和 split classloader 契约在解压副本通过。
- 使用用户提供的 libwebp 1.6.0 源码，在工作树与解压副本完成 host build、incremental 与 finite-loop fixtures。
- 最终项目包含 732 个文件、ZIP 954 个条目；逐文件字节、符号链接与执行权限往返一致，且不含禁止生成物。
- 当前环境仍无 Flutter/Dart SDK、Cargo/rustc 与 Android Gradle wrapper，未执行 analyzer、真实 Dart/Flutter tests、Rust tests 或 Android debug/release。
