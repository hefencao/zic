# dev.207 根因审计：版本更新提醒、跨版本图片复用与纵向回拉

## 基线与只读参考

唯一代码基线是 `zic_v0.31.0-dev.206_download-owner-partial-venera-rhttp-resolver.zip`。`vibevenera-master.zip`只读用于比较版本缓存复用边界，不复制其CacheManager/Pipeline实现。

## 1. 旧版卡没有 `!`

`_sourceComicHasUpdate`正确要求“已入书架 + SavedComic.sourceUpdateAt”。问题在signal生产：旧 `_rememberSourceSuccessors`只有 relation首次 `known.add`成功才写 `sourceUpdateAt`。relation若先被持久化、随后入架逻辑清过历史update signal，再次观察同一successor会直接返回，旧版因此永久没有`!`。

修复后 relation保存与signal reconcile分离。只要confirmed successor仍存在，就可把缺失的SavedComic update signal补回；`_loadSourceVersionState`也会在已有stored successor时先reconcile，因此本次source版本查询失败不影响已知relation的提醒。

## 2. 不迁移查看新版仍重新下载

现有artifact alias/rekey本身完整，但调用只位于 `_applySourceMigration`。`_viewSourceVersion`只是exact raw identity导航，因此新版Reader创建新的`DownloadId`后，ArtifactCacheManager没有new→old alias，必然miss并进入origin。

VibeVenera只读对比显示其做法是在查看新版前先匹配版本页面并注册session/cache alias；核心是“逻辑新key映射到已有旧key”，不是复制缓存实现。

ZIC dev.207在 `_prepareImportedChapter`、Pipeline/cache lookup之前调用 `_prepareSourceVersionArtifactReuse`：从持久`ComicVersionRelationStore`反查predecessor，匹配同sequence章节；manifest已有强identity先直接匹配。Venera opaque locator需要通过现有source request-plan解析最终媒体identity，首/中/末证明offset后构造new DownloadId→old DownloadId计划，`applyExisting`只给确实存在的旧artifact注册`ArtifactCacheManager.alias`。整个准备过程不读取媒体body、不写第二cache、不修改library状态。

## 3. 纵向静态图片上下滑动回拉

`ReaderView.didUpdateWidget`过去在 `verticalStitch`变化**或**整个 `pageAspectRatios` map变化时调用 `_preserveVerticalAnchor`。图片首帧/真实比例异步到达会不断改变ratio map；anchor restore随后post-frame `jumpTo`，与用户正在进行的纵向滚动竞争，表现为短距离被拉回。

dev.207只删除ratio-map变化触发的anchor保存。真实vertical stitch、viewport、DPR变化与显式navigation仍使用原有anchor/scroll定位，避免把必要的布局连续性一起删除。

## 验证重点

真机应观察：old-version source card在confirmed relation存在时右上`!`稳定；仅查看new-version Reader时trace出现`version-artifact-alias-prepared`且同页从artifact而非origin读取；纵向静态页持续上下拖动不再出现ratio收敛后的反向jump。
