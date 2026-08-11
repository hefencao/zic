# dev.224 Chapter migration compile closure

## 结论
用户本地Dart编译暴露dev.223迁移闭包未完全收口：durable artifact store的方法已迁移但write single-flight字段未迁移；LiveCoordinator helper仍引用上层`update`；另有重复`frameIndex`声明。三者均为编译级半迁移，不代表dev.223 ownership模型需要回退。

## 修复
- `_artifactWrites`归`PersistentDownloadArtifactStore`，因为它只保护durable artifact materialization与close barrier。
- `_reconcileDownloads`从自己的`_downloads`当前全集生成`TransferDemand`，不依赖`PipelineDelta`局部变量。
- 删除`advanceDueFrame`重复声明。
- 新增`tool/test_dev224_chapter_migration_compile_closure.py`，锁定上述迁移闭包并扫描相邻重复局部声明。

## 边界
本轮不修改NetLane、水位、retry、cache identity、resident replay、chapter claim或TransferKey；verified TransferKey继续冻结，先恢复用户本地Flutter/Dart编译。
