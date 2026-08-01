# ZIC 后续迭代提示词

下面的提示词用于新聊天或长聊天中断后的继续开发。使用时把最新完整项目包和错误日志一并上传，并替换 `<LATEST_ZIP>`、`<TARGET_VERSION>` 与当前任务。

```text
严格以我本次上传的 `<LATEST_ZIP>` 为唯一代码基线继续迭代，目标交付 `<TARGET_VERSION>`。
不得回退、混入或覆盖任何更早候选、补丁树或记忆中的源码。Mihon 与 VibeVenera 参考源码默认只读；除非我明确要求，不得修改或并入它们。VibeVenera 中由我们此前自行设计的 Pipeline/流式播放实现可以直接参考或迁移，但必须接入 ZIC 现有所有权边界，不能再建立竞争实现。

不要只给计划。必须实际阅读代码和文档、修改源码、运行当前环境能执行的检查、修复发现的问题，并交付完整 ZIP 与从上一完整版本生成的增量 patch。若环境缺少 Flutter/Dart/Android/Rust 工具，必须明确说明未执行哪些验证，不得用 Python 静态检查冒充编译或 Widget 测试。

开始前必须按顺序阅读：
1. `AGENTS.md`
2. `docs/NEXT_CHAT_HANDOFF.md`
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. 与本任务相关的最新 ADR
8. 错误日志、设备 trace 和我附带的参考实现

先建立三个清单，再改代码：
- 问题清单：编译错误、产品错误、性能问题、测试错误分别列出，不要混为一类。
- 所有权清单：每个状态、资源、命令和生命周期当前由哪个 package/class 拥有，正确所有者应是谁。
- 被否决方案清单：记录曾被我否决或已经证明退化的方案及原因，后续不得换名字重新实现。

Architecture 与所有权原则：
- `domain` 只定义领域实体、identity和值对象，不依赖 UI、插件、网络、缓存或平台桥。
- `catalog` 管漫画/章节/来源抽象与元数据，不拥有页面正文下载、解码、Reader 控制或页面 artifact。
- `resource_cache` 是封面、详情、搜索响应等网络响应缓存的唯一所有者。页面 artifact 不进入该平面；App/Reader 不得另建私有图片字节 LRU。
- `downloads`/`sessions` 管 DownloadSession、partial、resume、artifact 和持久下载状态。
- `pipeline`/`pipeline_runtime` 是下载、预取、重试、解码、上传、优先级、lane、进度投影和资源会话的唯一所有者。
- Reader 只能提交 `ReaderObs`、用户阅读命令和 Presentation 尺寸，消费只读 `PipelinePageStream`/进度/texture 或 ImageProvider。Reader 不得创建、销毁、选择或直接访问 DownloadSession、transport、artifact、decode/upload lane、预下载窗口或重试策略。
- `reader_runtime` 只负责 Reader Presentation、交互和 observation 适配，不重新拥有 Pipeline session。
- `plugin_host` 只负责信任、隔离、插件调用和 request plan。插件不得获得导航、Reader、demand、artifact 或 App 状态权限。普通图片正文由宿主流式 transport 进入同一 Pipeline，不经完整 JSON/Base64 RPC 往返。
- 平台实现必须由上层 composition 注入抽象。核心包不得反向依赖 Android/FFI `bridge`。例如 Pipeline 依赖 `SourceFactory`，而不是直接创建 `NativeSourceFactory`。
- `apps/app` 只组合 facade 和页面，不定义缓存算法、下载算法、预取策略、页面保活、插件传输或解码器。
- 设置与 Debug UI 只能投影和调用已有 facade，不能直接访问插件 Cookie、底层文件、transport 或 session registry。

当前不得随意改变的重要行为：
- VibeVenera 风格下载窗口保持前 7/后 3，预解码前 2/后 1，只上传 current/transition，lane 为 5/3/2；除非有明确实验、数据和我的批准，不得通过关闭预下载、缩小窗口或降低并发掩盖请求/流量错误。
- GET/HEAD 必须零 body，不能携带实体 headers。
- 同一 locator/request plan、下载 session、artifact 和 decode 任务必须按稳定 identity 合并，不得由首页、详情、Reader 各自重复请求。
- 已完成/promoted/restored 页面不得重新闪烁“连接中”或进度条。
- 连续 Reader 不裁切漫画内容，不用负位移或页面重叠掩盖接缝；几何单位统一为 `height / width`。
- 不得为了通过测试随意改变产品逻辑。若测试假设错误，修测试；若产品逻辑错误，修产品并增加正确回归。

耦合审查必须覆盖：
- 依赖方向：是否出现低层反向依赖高层、核心依赖平台桥、App 直接依赖内部实现。
- 状态重复：同一 current page、下载进度、缓存命中、插件状态是否存在两个权威来源。
- 命令重复：同一功能是否在顶部/底部、Reader/UI/Pipeline 或多个页面各有入口。
- 生命周期：谁创建、谁关闭；外部注入对象不得被错误关闭，owned 对象必须按依赖顺序关闭。
- 能力注入：相关能力应作为一个原子配置值绑定，避免多个 setter 形成半更新状态。
- API 泄漏：Presentation 不得看到 mutable session、transport enum、artifact store、插件内部对象或平台 handle。
- 测试归属：某实现的单元测试必须放在拥有它的 package。App 测试不得为了方便导入低层 `src/` 或重复测试 downloads/pipeline 的 identity 算法。
- 兼容层：只被测试引用、生产无调用、或仅转出低层内部类型的 facade/类/文件应删除。删除前使用全仓引用检查；交付说明中列出删除内容及原因。
- 文件规模：超大文件继续增长前必须按状态所有权拆分，而不是按随意 UI 片段拆分。拆分后不得制造循环 import、`part` 指令顺序错误或隐式全局状态。

实现流程：
1. 先复现或静态定位所有报告错误，逐项映射到真正所有者。
2. 优先修编译闭包，再处理产品错误；不得只改测试绕过编译或运行时问题。
3. 改动公共 API 时搜索全部生产与测试调用方，一次完成迁移；不得留下只在无 SDK 环境下看不出的漏导入、旧方法或旧类型。
4. 每次重构后运行全仓引用搜索，删除失效导出、兼容 facade、重复测试和死文件。
5. 为重要所有权边界增加静态门禁，但静态门禁只是补充，不能替代 analyzer、Flutter test 或设备验证。
6. 测试使用稳定 key、状态对象或可控 Future 同步；禁止固定 pump 猜异步完成，禁止对 lazy child 直接 `.single`，禁止用脆弱文本包含匹配作为唯一身份。
7. Trace 使用 hash/长度摘要，不打印完整 Mihon/Venera Base64 token；高频事件可在诊断投影合并，但错误和权威 telemetry 不得丢失。
8. 更新 README、CHANGELOG、Architecture、Spec、Plan、Status、Handoff 和必要 ADR，使文档与实际代码所有权一致。发现旧文档与当前架构冲突时应直接修正，不得继续复制过时描述。

验证顺序：
- `flutter analyze`
- 受影响 package 的 Dart/Flutter 测试；拆出的 composition package 必须显式出现在 analyzer/test runner 中，不能只跑 App
- App 目标测试
- Android debug/release 构建或至少 kernel snapshot
- 仓库静态门禁、Android/Mihon/Venera 契约
- 完整包重新解压后复验
- 在上一完整基线上应用 patch 后复验
- 比较完整包树与 patch 重建树逐文件一致

交付要求：
- 提供清晰版本号和中文提交标题。
- 提供完整项目 ZIP 和上一版本到本版本的 patch。
- 提供二者 SHA-256。
- ZIP 必须干净，不含 `.git`、`.dart_tool`、`build`、`.gradle`、`__pycache__`、`.pyc`、`.class` 等生成物。
- 总结实际修改、删除的冗余文件、Architecture/耦合变化、测试结果和未验证项。
- 不得把“静态字符串检查通过”描述为“Flutter 编译通过”。

当前任务：
<在这里粘贴本轮错误、设备现象和功能要求>
```

## 使用建议

新聊天中应同时上传最新完整 ZIP、最新错误日志和必要截图。若需要参考 VibeVenera/Mihon，再上传对应参考包，并明确哪些内容只读、哪些自有模块允许直接迁移。
