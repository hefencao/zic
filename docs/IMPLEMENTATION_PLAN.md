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

下一步：

- 在相同设备和 WebP fixture 上采集 dev.102 Trace；
- 比较 platform schedule queue、channel dispatch、native decode、source wait 和 upload backpressure；
- 验证 asynchronous schedule 后 blit lane 不再被 main-thread queue 串行阻塞；
- 关联两次 current decode failure 的 source epoch、frame、worker 和 native 错误；
- 复验 50% 交接、前 12 帧和页面回切。

退出条件：current 前帧没有无法归因的数秒空洞；50% 交接无黑屏和同 identity 重载；decode failure 有可行动原因。

## P0：Flutter 与 Android 验证闭包

下一步：

- 运行 `flutter analyze`；
- 运行受影响 package tests 和 App tests，确认 quarantine 与 cold-open 修复；
- 构建 Android debug/release；
- 区分产品错误、测试错误和环境错误，不以改产品逻辑迎合过时测试。

退出条件：结果进入 validation audit；所有失败均有明确所有者和处理结论。

## P1：共享 artifact stream 设备验证

下一步：

- 从 Trace 读取 `readSchedulerWaitMicros`、priority、页面角色和跨 session 最大并发；
- 验证总并发不超过 5，background 最多占 4，current/transition 可使用保留槽；
- 验证 background→current 晋升不取消、不重开同一 artifact stream；
- 比较 source first-chunk、stream 和 current source-wait 的变化。

退出条件：共享调度行为与 Pipeline demand 一致，且没有引入 current starvation 或预下载退化。

## P1：解除 Source Browser quarantine

当前登记：`Q-001`、`Q-002`、`Q-003`。

下一步：为 locator refresh、persisted Venera refresh 和 transient retry 建立直接 facade/widget harness，移除对主页、lazy list 和真实网络时序的依赖。

退出条件：对应测试不再 `skip`，失败能直接指向 owner。

## 每轮收尾

1. 全仓引用搜索并删除死兼容层。
2. 执行当前环境可用的门禁和目标测试。
3. 更新 Status、Handoff、CHANGELOG 和本轮 audit。
4. 干净打包，并从 ZIP 独立解压复验。
