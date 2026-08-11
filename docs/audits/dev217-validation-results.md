# dev.217 验证结果

日期：2026-08-11
目标版本：`0.31.0-dev.217` / App `0.31.0+217`

## 当前环境

- Dart / Flutter SDK：均不可用，因此不宣称Dart行为测试、`flutter analyze`或APK build通过。
- Kotlin compiler：可用；dev.206 Kotlin facade stub compile实际通过，仅有stub未使用参数warning。
- 唯一dev.216基线继续缺少`third_party/source_archives/libwebp-1.6.0.zip`；未从旧版本或独立包补入。

## Trace 与根因验证

设备Trace共6744条事件；`downloadStarted=257`但仅40个unique identity，175次同identity再次start间隔小于1秒，最短约151µs；同时记录51次`sessionBusy`、2次`writerBusy`以及114次由`sessionBusy`放大的`download-attempt` retry。源码审计确认dev.216 `_ensureDownloadTask()`在已有task key时迁移priority后没有return，queued task尚未`activeRun`时会继续生成第二key。

## 已实际执行并通过

- `tool/check_documentation.py`、`check_dart_structure.py`、`check_test_quarantine.py`；
- UI architecture、Reader streaming、Pipeline demand stability、Pipeline runtime compile-boundary；
- dev.174、175、183–192的current/prefetch/preemption/transport相关适用门禁；dev.185历史门禁已从旧`reader:<id>`字面key改为当前`downloadTaskKeyFor(id)`行为断言；
- dev.199及dev.209、211–217的适用ownership/version gates；
- dev.206 Download owner / Venera rhttp boundary（含Kotlin stub compile）；dev.215 ingress projection与dev.216 composition owner gates。

## 完整check的真实状态

`bash tool/check.sh`仍在第一项pinned libwebp presence检查处停止：唯一基线缺少`third_party/source_archives/libwebp-1.6.0.zip`。因此不宣称完整check通过。

## dev.217闭合条件

1. 同一exact `DownloadId`已有queued/active physical task时，revision只迁移priority并保持同一task key。
2. 只有NetLane已经退休旧key时才允许新submit；stale lane entry不得开始第二run。
3. `activeRun`与`hasWriter`均阻止第二physical admission。
4. 新Dart回归覆盖NetLane被block时连续700→720→780→1000 revision，要求queued task始终只有1个且transport只open一次。当前环境无Dart SDK，该测试已实现并做结构审计，但尚未运行。
5. dev.214–216的claim/projection/composition owner方向保留；不通过回退Reader-local registry、提高并发、增加retry或改prefetch窗口掩盖本次回归。

设备复验应首先确认`sessionBusy/writerBusy`归零或不再由owner内部竞争产生，并观察不同图片的prefetch重新按priority占用NetLane；在此之前暂停verified TransferKey-before-acquire扩展。
