# zic Implementation Plan

本文件只列未完成工作。完成历史位于 `CHANGELOG.md`，单轮证据位于 `docs/audits/`。

## 执行原则

1. 只以最近交付的完整 ZIP 为代码基线。
2. 先恢复编译闭包，再修产品错误和性能问题。
3. 改动落在真正所有者；App 和 Reader 不建立竞争缓存、session 或 texture 实现。
4. 优化必须有可比较的 Trace 或设备证据；不得缩小 7/3、2/1 或 lane 5/3/2 掩盖错误。
5. 每轮默认只更新 Status、Handoff、CHANGELOG 和 audit；稳定合同未变化时不修改 Architecture/Spec。

## P0：Android native texture 设备闭环

- 采集 dev.108 首次进入、快速退出重进和频繁切页 Trace；
- 确认 presentation path 从全量 `flutterFallback` 恢复为 `platform`；
- 检查 `platformConfigureMicros` 与 `blitRetryCount` 只在首次、resize、Surface 重建或一次 lock retry 出现；
- 若 status 4 仍存在，区分 configure failure、Surface lifecycle 与 buffer size/format。

## P0：统一 artifact cache 路由验证

- 确认 current 快速重进由中央 manager 命中 memory tier；
- 检查 manager key/length、backend miss、read join、invalidate 与 write-through；
- 验证 handoff 不再调用 backend-specific presence；
- 比较首次与重进的 materialize、session-copy、source-ready 和首帧。

## P0：Reader dispose 与播放连续性

- 检查 lane `cancelAll()` 后 coordinator dispose 长尾；
- 验证旧 Reader 不再与新 Reader 的 current decode/upload/texture 大量重叠；
- 继续验证新 current 自动播放、retained cursor 和 successor 水位。

## P0：Flutter 与 Android 工具链闭包

运行 `flutter analyze`、受影响 package/App tests、Android debug/release；失败必须区分产品、测试和环境所有者。

## P1：解除 Source Browser quarantine

为 `Q-001` 至 `Q-003` 建立直接 facade/widget harness，移除主页、lazy list 和真实网络时序依赖。

## 每轮收尾

全仓引用搜索、可用门禁、Status/Handoff/CHANGELOG/audit 更新、干净打包与 ZIP 独立解压复验。
