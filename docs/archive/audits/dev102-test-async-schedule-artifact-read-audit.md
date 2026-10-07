# dev.102 测试闭包、异步 texture 与 artifact 读取审计

## 基线

唯一源码基线：`zic_v0.31.0-dev.101_documentation-boundary-schedule-timing.zip`。

输入：

- `错误报告(52).txt`
- `zic-debug-trace-2026-08-03T09-14-47.jsonl`

## 问题清单

### 编译错误

1. `source_browser_test.dart` 的三项 quarantine 把字符串传给 `testWidgets(skip:)`；当前 Flutter API 需要 `bool?`，导致整个测试文件无法编译。
2. cold-open 测试触发 `Future.catchError` 返回类型检查；non-void artifact read 使用了弱类型异步错误链。

### 产品错误

1. Android texture 的唯一 blit lane 在每次 present 后用 latch 等待 platform thread。即使 retain/blit 已完成，其他 output 仍不能使用 blit lane。
2. 两个并存 Reader session 各自拥有本地 persistent artifact stream 并发，composition 没有共享上限。
3. pending artifact read 若以 background priority 入队后晋升 current，固定 priority 无法使用保留槽。

### 性能问题

新 Trace 共包含 208 条 `framePipelineTiming`：

- `platformScheduleQueue` 为 85 条 dominant；
- native decode 为 63 条；
- channel dispatch 为 28 条；
- upload backpressure 为 20 条；
- end-to-end p50 约 306 ms，p95 约 2.74 s，最大约 7.49 s；
- platform schedule queue p95 约 211 ms、最大约 447 ms，而 schedule call 最大约 24 µs；
- 32 次 persistent artifact source read 的跨 session 峰值并发为 10，stream p95 约 2.15 s；
- 出现 2 次 current decode failure，执行时间分别约 23.5 ms 和 42.4 ms，仍缺少 native 失败细节。

这些数值只描述 dev.101 输入 Trace，不是 dev.102 设备验证结果。

### 测试错误

1. quarantine 表达方式本身破坏编译，应保留稳定 ID 和登记，但改用布尔 skip。
2. cold-open 目标仍有效；失败来自产品异步错误链，不应删除该测试。

## 所有权清单

| 状态、资源或命令 | 修改前所有者 | 正确所有者 | dev.102 处理 |
|---|---|---|---|
| quarantine 原因与解除条件 | test 文件字符串参数 | repository tooling + 登记表 | `skip: true` + 同语句稳定 ID 注释 |
| promoted artifact read Future | `downloads` read pool | `downloads` | 显式 typed completer / error bridge |
| Reader session dispose error | Presentation host 的弱 Future 链 | `pipeline_runtime` host | typed async guard |
| native runtime prewarm error | factory 弱 Future 链 | `pipeline_native` composition factory | typed async guard |
| Android retain/blit/schedule/reply | `texture_bridge` | `texture_bridge` | 异步 main schedule，同 runnable reply |
| persistent artifact stream 并发 | 每个 Reader session 各自隐式拥有 | composition-shared `downloads` scheduler | 5 个全局槽，1 个 foreground 保留槽 |
| artifact page role priority | transport 入队时固定值 | Pipeline 当前 demand | callback 动态读取，plan 变化刷新 |
| 并发和等待 telemetry | 无跨 session 投影 | `downloads` + analyzer | priority、scheduler wait、max concurrent |

## 被否决方案清单

1. 缩小 7/3、2/1 或降低 lane 并发：未修复跨 session 重复所有权。
2. 关闭预下载：会损失 successor，且与既定行为冲突。
3. 从 blit worker 直接调用需要 platform thread 的 schedule：线程合同不明确且破坏现有平台边界。
4. 在 schedule 前提前回复：可能再次产生 playback 与 texture 可见状态竞态。
5. 用 App/Reader 私有 semaphore 限制文件读取：泄漏底层实现并形成竞争策略。
6. role 晋升时取消旧 stream 再以 current 重开：重复读取并丢弃有效进度。
7. 删除 cold-open 测试：其产品目标有效，应该修产品异步错误链。

## 实现结果

- 三项 quarantine 改为可编译的 `skip: true`，原因和稳定 ID 保留在注释及登记表。
- non-void artifact read、Reader session dispose 和 runtime prewarm 使用强类型 async error handling。
- Android blit lane 不再等待 platform thread；schedule 和 result reply 位于同一个 main-thread runnable。
- 新增 process-shared artifact read scheduler；所有 `with...` factory 保持同一 scheduler identity。
- pending priority 动态读取 Pipeline 当前 plan，并在 observation/detach 后刷新。
- 新增 scheduler 单元测试和 dev.102 ownership gate。
- Trace analyzer 增加 scheduler wait 与跨 session 最大 source-read 并发。

## 未验证

- 当前环境无 Flutter/Dart SDK，错误报告对应测试未在本机执行。
- 当前环境无完整 Android 构建工具链和设备，异步 schedule 与共享 artifact scheduler 尚无 dev.102 真机结果。
- 两次 current native decode failure 仍需下一轮增加或读取更底层错误信息。
