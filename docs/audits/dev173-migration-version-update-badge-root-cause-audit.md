# dev.173 漫画源迁移 / 同源版本 / 更新提示审计

## 历史对比

只读对比 dev.135、dev.145→146、dev.146→147 变更后确认：

- dev.135 已存在通用 `_selectSourceMigrationTarget` 与 `_openSourceMigration`，跨源搜索后统一进入严格迁移比较。
- dev.146 主要移除了详情 AppBar 的“迁移漫画源/查看同源版本”入口，并把版本能力转向正文 version notice。
- dev.147 才删除通用 target selector 与 `_openSourceMigration*`，同时增加 exact raw version view、predecessor/successor 双向关系和独立“查看/迁移”动作。
- 后续 `_applySourceMigration`、`ComicSourceMigrationPlan`、`showSourceMigrationComparison` 并未删除；`ComicVersionRelationStore` 与 `sourceUpdateAt` 反而进一步完善。

因此本轮不回滚到旧实现，而是在当前 owner 上恢复通用选择入口。

## 当前问题

1. source card 的 shelf 标记使用 `collections_bookmark`，视觉上更像“收藏”，且用户要求左上明确书架标志。
2. 通用跨源迁移入口缺失；同源版本能力只在详情正文快捷区暴露。
3. source-confirmed 新章节/新 successor 已能推进 `sourceUpdateAt`，Home更新列表可见，但漫画源页没有对应的更新提示与直接查看入口。
4. `_applySourceMigration` 直接调用底层 `saveComicPreference`，可能在 same-canonical raw version替换后留下旧 alias preference，造成旧/新版同时显示 shelf membership。

## dev.173 收口

- source card：左上 `Icons.library_books` + dim 表示 shelf；右上 `priority_high` 表示当前 shelf comic存在 `sourceUpdateAt`。
- Home向 `ComicSourcesPage` 注入 `hasUpdate/onOpenUpdate`，source browser不拥有 update store。
- 恢复详情 AppBar“迁移漫画源”和通用 selector；当前 source默认可选，同源版本走 source-confirmed relation，跨源才允许标题搜索。
- confirmed version chooser同时提供“查看”和“迁移”；查看 exact raw identity，迁移调用现有 `_migrateSourceVersion/_applySourceMigration`。
- update badge点击优先解析 successor并 `_viewSourceVersion`；没有 successor则打开当前详情。
- migration preference写入改走 `_savePreference`，复用 canonical alias去重规则。

## 未改变

- 不新增第二 migration store、第二 version relation store或 source-page shelf/update cache。
- 不从标题相似度建立 same-source relation。
- 不改变 Reader/Pipeline/download/artwork ownership。
- 本轮不定义“已看过更新”持久状态；`sourceUpdateAt` 的 acknowledged语义仍待单独产品决策。
