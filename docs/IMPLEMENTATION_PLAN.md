# zic Implementation Plan

本文件只列未完成工作。完成历史位于 `CHANGELOG.md`，单轮证据位于 `docs/audits/`。

## 执行原则

1. 只以最近交付的完整 ZIP 为代码基线。
2. 先恢复编译闭包，再修产品错误和性能问题。
3. 改动落在真正所有者；App 和 Reader 不建立竞争缓存、session 或 texture 实现。
4. 优化必须有可比较的 Trace 或设备证据；不得缩小 7/3、2/1 或 lane 5/3/2 掩盖错误。
5. 每轮默认只更新 Status、Handoff、CHANGELOG 和 audit；稳定合同未变化时不修改 Architecture/Spec。

## P0：Reader 重进清理设备闭环

- 采集 dev.107 首次进入、快速退出重进和未稳定切页 Trace；
- 确认相同持久 artifact 的 handoff 为 `skip-existing`，`handoffDrainMicros` 不再形成秒级长尾；
- 确认旧 Reader dispose 不再覆盖新 Reader 的主要播放区间；
- 比较新旧 session 的 dispose 分阶段耗时。

## P0：progressive ingress 与前帧水位

- 确认 current/transition 使用 `deliveryMode=startup-segmented`；
- 验证首个 1 MiB 后 source-ready/decode 即可推进，不再等待完整文件；
- 检查 startup pressure、lease-through-stream 与 successor depth=2 的释放顺序；
- 继续关联 current decode failure 和新页无法播放。

## P0：Flutter 与 Android 验证闭包

运行 `flutter analyze`、受影响 package/App tests、Android debug/release；失败必须区分产品、测试和环境所有者。

## P1：解除 Source Browser quarantine

为 `Q-001` 至 `Q-003` 建立直接 facade/widget harness，移除主页、lazy list 和真实网络时序依赖。

## 每轮收尾

全仓引用搜索、可用门禁、Status/Handoff/CHANGELOG/audit 更新、干净打包与 ZIP 独立解压复验。
