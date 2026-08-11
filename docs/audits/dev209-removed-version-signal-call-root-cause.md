# dev.209 根因审计：已删除 version signal reconcile 的残留调用

## 现象

本地编译报告：

`lib/demo_home_source_migration.dart:303:13: Error: The method '_reconcileConfirmedSourceUpdateSignal' isn't defined for the type '_DemoHomeState'.`

## 根因

dev.208 正确删除了 dev.207 的 `_reconcileConfirmedSourceUpdateSignal()` 实现，因为 confirmed version relation 已经作为 `HomeLibrarySession.versionRelations` 的一等投影事实，不能再镜像写入章节/目录更新字段 `SavedComicRecord.sourceUpdateAt`。

但 `_loadSourceVersionState()` 中保留了一个旧调用：在读取 `storedSuccessors` 后尝试执行已经删除的方法。这个调用没有任何新的 owner 职责：版本状态本身随后直接合并 stored predecessor/successor relation 与 `findComicVersions()` 结果；Home/source browser 的更新提示也直接读 relation projection。因此它只是半删除接口残留，恢复旧方法会重新引入 dev.208 已明确移除的跨事实写回。

## 修复

- 删除 `_loadSourceVersionState()` 中残留的 reconcile 调用，不增加替代副作用。
- dev.208 gate 从只禁止 `Future<void> _reconcileConfirmedSourceUpdateSignal(` 定义，升级为禁止迁移生产文件中出现 `_reconcileConfirmedSourceUpdateSignal` 任意引用。
- 新增 dev.209 closure gate，同时检查当前 relation owner仍存在：stored predecessor/successor、`_rememberSourceSuccessors()`、`HomeLibrarySession.upsertVersionRelation()`、`_projectedConfirmedSourceUpdateAt()`。
- dev.209 gate 接入 `tool/check.sh`，使缺少 Flutter/Dart SDK 的发行环境也能发现该类半删除符号。

## 未改变

- 不恢复 relation → `sourceUpdateAt` 镜像。
- 不改 dev.208 confirmed relation Home projection。
- 不改双向 artifact reuse / alias 图规则。
- 不改 dev.207 vertical ratio-anchor 修复。
- 不改 Reader/Pipeline、Venera/Mihon transport 或缓存 owner。
