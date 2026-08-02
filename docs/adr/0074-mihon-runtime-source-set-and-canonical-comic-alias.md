# ADR 0074: Mihon runtime source set 与 canonical comic alias

- 状态：Accepted
- 版本：0.31.0-dev.90
- Supersedes：ADR 0010 的精确 ID 路由部分

## 背景

`generateMihonAbiAssets` 使用嵌入式 Kotlin 编译器，只编译 Mihon ABI 源码与 `network_bridge/android/src/runtime/kotlin`。`AndroidCookieJar` 通过 `AndroidBrowserCookieSession` 间接依赖 `NetworkBrowserSnapshotStore`，而 store 位于仅普通 AAR main 编译可见的位置，导致隔离 ABI 编译缺类。

设备 Trace 同时显示同一 Mihon source 下存在两个漫画 ID：长度 439 的记录可恢复 342 章，长度 440 的记录始终为 1 章；两者 `syntheticChapterCount=0`。Mihon bridge 将整份可变 SManga JSON 编码进 `comicId`，详情补齐标题、简介或 memo 后，同一作品 URL 会产生不同持久 locator。

## 决策

1. 将 `NetworkBrowserSnapshotStore` 放入 network runtime source set。普通 network AAR 与 Mihon asset 编译复用同一文件；加入 runtime class verification 和 R8 keep。
2. raw opaque `comicId` 继续作为插件请求 locator，不改写。部分扩展可能依赖其中的 memo 或模型字段。
3. `CanonicalComicIdentitySource` 返回 comparison-only 同源等价值；Mihon/Venera 以规范化作品 URL 实现。
4. alias collapse 和最优 raw locator 选择属于 `catalog`。App composition调用该能力完成首页/书架投影、来源卡片路由、preference 合并和目录回归检查。
5. 详情 Presentation只接收 identity matcher。canonical-equivalent 的原子快照是合法结果，不能因 raw ID 不同显示失败。
6. canonical group 曾有多个真实章节后，空、synthetic-only 或单章节结果不得覆盖。
7. 删除只被旧门禁/文档引用的 `resolveComicDetailsRoute`。

## 后果

- 同一作品不再因可变 SManga 字段显示两份卡片。
- 加载仍使用扩展原始 locator，不牺牲 Mihon 兼容性。
- storage 可暂时保留历史 alias 记录；它们在只读投影中合并，不进行破坏性 chapter ID 迁移。
- Trace 能通过脱敏 canonical hash 识别 alias，而不泄漏 opaque token。
