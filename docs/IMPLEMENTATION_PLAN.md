# zic Implementation Plan

本文件只列未完成工作。完成历史位于 `CHANGELOG.md`，单轮证据位于 `docs/audits/`。

## 执行原则

1. 只以最近交付的完整 ZIP 为代码基线。
2. 先恢复编译闭包，再修产品错误和性能问题。
3. 改动落在真正所有者；App 和 Reader 不建立竞争缓存、session 或 texture 实现。
4. 优化必须有可比较的 Trace 或设备证据；不得缩小 7/3、2/1 或 lane 5/3/2 掩盖错误。
5. 每轮默认只更新 Status、Handoff、CHANGELOG 和 audit；稳定合同未变化时不修改 Architecture/Spec。

## P0：promoted artifact 读取设备闭环

- 在同一设备/fixture 采集 dev.105 首次进入、快速退出重进和未稳定时切页 Trace；
- 验证 current/transition 出现 `artifactReadMode=read-all`，重进出现 `memory-hit`；
- 比较 open、materialize、first chunk、完整 stream 和 source wait；
- 确认 cache hit 不再执行多余的 DownloadSession restore/prefix/index 状态链，也没有回退原始 `content://`；
- 观察 4 项/96 MiB cache 的淘汰是否符合当前/transition 工作集。

退出条件：数秒级文件读取长尾显著下降，快速重进不重复读取同一 promoted artifact，且首帧不因整文件快速路径退化。

## P0：前帧播放与切页连续性

- 继续复验 current/transition 50% 交接、retained cursor 和新页自动播放；
- 关联 remaining current decode failure 的 source epoch、frame、worker 与 native 错误；
- 确认预解码实际产生 successor，而不是只完成 encoded-byte 预读。

## P0：Flutter 与 Android 验证闭包

运行 `flutter analyze`、受影响 package/App tests、Android debug/release；失败必须区分产品、测试和环境所有者。

## P1：解除 Source Browser quarantine

为 `Q-001` 至 `Q-003` 建立直接 facade/widget harness，移除主页、lazy list 和真实网络时序依赖。

## 每轮收尾

全仓引用搜索、可用门禁、Status/Handoff/CHANGELOG/audit 更新、干净打包与 ZIP 独立解压复验。
