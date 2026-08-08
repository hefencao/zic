# ADR 0156：漫画源迁移、同源版本查看与更新提示的所有权

## 状态

Accepted，dev.173。书架标志视觉与通用迁移入口部分取代 ADR 0154/早期 dev.146–147 的对应 UI 决策；其筛选与下载反馈规则不变。

## 背景

历史上 ZIC 曾提供通用“迁移漫画源”入口。dev.146 从详情 AppBar 移除了该入口，dev.147 随后删除通用目标选择器，同时强化了同源版本的 exact raw identity 查看/迁移。之后 `ComicVersionSource`、`ComicVersionRelationStore` 与 `SavedComicRecord.sourceUpdateAt` 又分别形成了版本关系和更新事实，但 UI 缺少一个统一、可解释的入口。

如果直接恢复旧代码，会重新混淆三种不同事实：书架 membership、版本 relation 和显式 migration command；如果只保留同源版本快捷按钮，则跨源迁移能力缺失。

## 决策

1. 书架状态唯一来自 Home/library canonical `ComicPreference`。漫画源卡片只做投影：左上书本/书架图标并降低封面亮度，不建立 source-page shelf store。
2. `sourceUpdateAt` 是 source-confirmed update signal，不是 membership。已入书架且 signal存在时，漫画源卡片右上显示独立感叹号。点击后若 `ComicVersionSource/ComicVersionRelationStore` 已确认 successor，则直接查看目标 raw version；否则打开当前详情。提示本身不自动迁移、不自动加入 successor 到书架。
3. 恢复通用“迁移漫画源”详情入口。目标可以是当前 source 或其它已启用 source：
   - 同源候选只接受 `ComicVersionSource` 或持久化 relation；标题搜索不得建立同源关系。
   - 跨源可以用标题搜索发现候选，也可以手填原生 ID；搜索结果只是候选，不代表同一作品已被系统确认。
4. 同源版本在通用迁移面板中提供两个动作：`查看`直接打开 exact raw detail；`迁移`进入迁移流程。现有详情正文版本快捷入口可以继续存在，但最终调用同一个查看/迁移 owner。
5. 所有迁移统一经过 `ComicSourceMigrationPlan` 与 `showSourceMigrationComparison`。只有 `ChapterMigrationConfidence.exact` 的章节复制阅读位置/已读状态；sequence-only只展示风险。
6. 同源 raw locator 替换完成后，新 preference 必须经 `_savePreference` 写入，以清理 canonical alias 上旧的 shelf/liked/collected/category状态；不得绕过 Home preference projection直接写底层 store。

## 后果

- “查看版本”不会改变 SavedComic、阅读状态、版本关系或书架 membership。
- “迁移”是显式、有确认的状态变更；跨源与同源没有第二套迁移执行器。
- “有更新”只是事实提示；本轮不新增 acknowledged/seen update store。
- 若未来要在 successor 卡自身显示“这是你书架作品的新版本”，应新增 relation projection，而不是把 successor伪装成 `inShelf=true`。
