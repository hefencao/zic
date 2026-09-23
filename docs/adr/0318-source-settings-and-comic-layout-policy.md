# ADR 0318：源设置 ownership 与每漫画布局策略收口

## 状态
Superseded

来源设置 ownership 决策仍保留为历史依据；每漫画 adaptive/layout 的第 7–9 项由 ADR 0319 取代。

## 问题
来源管理此前把三类不同语义混在多个入口：

- 条漫置信已经按 `sourceId` 持久化，却以独立条漫图标暴露；
- 下载目录运行时和持久化也早已按 `sourceId`，但 UI 仍挂在插件行，并把一个目录批量写给插件的全部来源；
- 历史缓存冲突信任则真正按 `pluginId` 持久化，再由 source 反查 owner plugin。

与此同时，原齿轮入口实际编辑的是来源自身暴露的扩展属性、账号和登录会话，不是 ZIC 对该来源的应用级策略。
Reader 的每漫画设置又同时存在 master、独立 adaptive switch 和方向 dropdown，产生两个重叠的布局决策入口。

## 决策
1. 来源管理中的齿轮统一表示 **源设置**。ZIC 应用级、按 `sourceId` 生效的策略集中在该页：
   条漫置信、历史缓存冲突数据信任、来源独立下载目录。
2. 原来源插件设置/登录入口改称 **来源属性与登录**，使用属性列表/属性页图标，而不是齿轮。
   它只编辑 `ConfigurableComicSource` 自己暴露的属性和账号能力，不持有 ZIC source policy。
3. 来源独立下载目录从插件管理迁到源设置。它继续使用既有 `sourceDownloadDirectories[sourceId]` authority，
   只改变该来源未来新 artifact/partial 的 placement；已有 durable bytes 仍按索引 locator 读取，不在此自动迁移。
4. 历史缓存冲突信任的新 authority 为 `sourceTrustConflictingHistoricalCarriers[sourceId]`。
   resolution 顺序为 source override → 旧 plugin override 兼容 → application global default。
5. 第一次从某个旧插件来源进入源设置时，若存在旧 plugin override，
   必须把它一次性展开到该插件当前所有已知 source IDs，并删除旧 plugin override。
   已有显式 source override 不得被覆盖。这样随后任一来源的“跟随全局”都能真正清除本地 override。
6. 插件管理页只保留插件生命周期责任：安装/更新、payload 编辑、重试、错误、移除。
   不再展示来源下载目录或来源数据读取策略。
7. 每漫画 Reader 布局改为单一互斥策略胶囊：
   `自适应 / 跟随 / LTR / RTL / 纵向`。
   独立“使用自适应设置”开关删除；自适应本身就是布局策略之一。
8. “启用本漫画设置”是所有漫画级 override 的总 gate。
   master 关闭时全局自适应继续按全局设置生效，历史 `comicAdaptiveEnabled=false` 不得单独越过 master。
9. 兼容旧数据：若历史记录是 `enabled=false && adaptiveEnabled=false`，
   读取时迁移为 `enabled=true && adaptiveEnabled=false && directionOverride=null`，
   即新的“跟随”策略，以保持过去“只对这本漫画停用自适应”的实际行为。

## 后果
源设置现在与真实 runtime key 对齐；插件管理不再伪装成 source policy owner。
下载目录不再出现“插件有多个来源却只显示一个目录”的歧义。
Reader 的漫画级布局只有一个决策轴，自适应和固定方向不再由两个控件交叉决定。
