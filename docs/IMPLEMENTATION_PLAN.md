# zic Implementation Plan

本文件只列未完成工作。完成历史位于 `CHANGELOG.md`，单轮证据位于 `docs/audits/`。

## 执行原则

1. 只以最近交付的完整 ZIP 为代码基线。
2. 先恢复编译闭包，再修产品错误和性能问题。
3. 改动落在真正所有者；App 和 Reader 不建立竞争缓存、session 或 texture 实现。
4. 优化必须有可比较的 Trace 或设备证据；不得缩小 7/3、2/1 或 lane 5/3/2 掩盖错误。
5. 每轮默认只更新 Status、Handoff、CHANGELOG 和 audit；稳定合同未变化时不修改 Architecture/Spec。

## P0：启动前景压力设备闭环

- 采集 dev.106 首次进入、快速退出重进和未稳定切页 Trace；
- 确认 current/transition 使用 `deliveryMode=whole-body`，foreground lease 覆盖 body consumption；
- 检查 `readSchedulerPressureHolds` 在首帧与 successor 水位形成前保持，随后释放；
- 比较 mount-to-first-frame、前 12 帧 end-to-end、source stream、output prepare 和 platform presentation；
- 确认 pressure 释放后 background 7/3 继续推进，没有饥饿。

退出条件：首帧和前几帧的秒级拥堵显著下降，未稳定切页不再继承启动队列长尾。

## P0：切页播放连续性

- 继续复验 current/transition 50% 交接、retained cursor 和新页自动播放；
- 关联 remaining current decode failure 的 source epoch、frame、worker 与 native 错误；
- 确认预解码实际产生 successor，而不是只完成 encoded-byte 预读。

## P0：Flutter 与 Android 验证闭包

运行 `flutter analyze`、受影响 package/App tests、Android debug/release；失败必须区分产品、测试和环境所有者。

## P1：解除 Source Browser quarantine

为 `Q-001` 至 `Q-003` 建立直接 facade/widget harness，移除主页、lazy list 和真实网络时序依赖。

## 每轮收尾

全仓引用搜索、可用门禁、Status/Handoff/CHANGELOG/audit 更新、干净打包与 ZIP 独立解压复验。
