# zic Implementation Plan

本文件只列未完成工作。完成历史位于 `CHANGELOG.md`，单轮证据位于 `docs/audits/`。

## 执行原则

1. 只以最近交付的完整 ZIP 为代码基线。
2. 先恢复编译闭包，再修产品错误和性能问题。
3. 每项改动必须落在真正所有者；App 和 Reader 不建立竞争实现。
4. 公共 API 修改必须一次迁移全部生产和测试调用方。
5. 优化必须有可比较的 Trace、基准或设备证据；不得缩小 7/3、2/1 或 lane 5/3/2 掩盖错误。
6. 静态门禁不能替代 Flutter、Android 或设备验证。
7. 每轮默认只更新 Status、Handoff、CHANGELOG 和 audit；稳定合同未变化时不修改 Architecture/Spec。

## P0：前帧播放链设备闭环

目标：解释并降低 Animated WebP 前几帧的长尾停顿。

下一步：

- 采集包含 `platformScheduleQueueMicros` 和 `platformScheduleCallMicros` 的 Android Trace；
- 分别比较 platform queue、schedule call、native decode、channel dispatch、source wait 和 upload backpressure；
- 关联 current decode failure 的 source epoch、worker 和 native error；
- 在相同文件、窗口和设备条件下复验 50% 交接与前 12 帧。

退出条件：新字段能够解释主要长尾；current 前帧没有无法归因的数秒空洞；50% 交接无黑屏和同 identity 重新加载。

## P0：Flutter 与 Android 验证闭包

下一步：

- 运行 `flutter analyze`；
- 运行受影响 package tests 和 App tests；
- 构建 Android debug/release；
- 区分产品错误、测试错误和环境错误，不以改产品逻辑迎合过时测试。

退出条件：结果进入 validation audit；所有失败均有明确所有者和处理结论。

## P1：本地 artifact stream 归因

下一步：

- 区分文件系统读取、Dart stream 调度、session copy 和 native ingress；
- 记录同一 artifact 的并发 reader 数和页面角色；
- 检查是否存在重复整页 materialization 或不必要的 session copy；
- 只在证明 background stream 阻塞 current 后调整调度，不关闭预下载。

退出条件：current source wait 可与 near/background 读取分开，优化前后使用同一 fixture 比较。

## P1：解除 Source Browser quarantine

当前登记：`Q-001`、`Q-002`、`Q-003`。

下一步：为 locator refresh、persisted Venera refresh 和 transient retry 建立直接 facade/widget harness，移除对主页、lazy list 和真实网络时序的依赖。

退出条件：对应测试不再 `skip`，失败能直接指向 owner。

## 每轮收尾

1. 全仓引用搜索并删除死兼容层。
2. 执行当前环境可用的门禁和目标测试。
3. 更新 Status、Handoff、CHANGELOG 和本轮 audit。
4. 干净打包，并从 ZIP 独立解压复验。
