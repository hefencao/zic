# dev.119 预加载唤醒与静态输出驻留审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.118_local-direct-ingress-visible-output.zip`
- 设备证据：`zic-debug-trace-2026-08-04T07-39-43.jsonl`

## 问题分类

### 产品问题

- 纵向静态页进入视口前虽已有 download/decode/upload demand，但 frame 0 未完成，滑动时仍显示 loading。
- 已成功呈现的静态页退出 upload demand 后立即释放 output；反向滑动需要重新建立 output。
- 轻量 page host 使用固定正负四页保活，与 7/3 资源窗口和实际内存无关。

### 运行时问题

- `sourceReady` 唤醒被全局 staged refill 重定向后丢失。
- 后续普通 refill 对 `DecodeState.waitingSource` 直接返回，已就绪 source 无法再触发该页解码。
- `_decodeSourceRevisions` 在实际 fill 前更新，取消或重定向可能错误消费 source revision。

### 架构问题

- dev.118 通过 `PageRole.visible` 补救屏幕内页面，绕开了预加载失效与 output 过早销毁两个根因。
- upload demand 生命周期被误当作 output 生命周期；FrameBudget 无法裁决已失去 demand 的静态 output。

## 所有权

- source revision 与 decode wake：`sessions/LiveCoordinator`。
- 静态 output 驻留与回收：`sessions/UploadSession`、`FrameBudgeter`。
- 页面角色与预加载选择：`pipeline`。
- 轻量纵向 host 生命周期：`reader`。

## 拒绝方案

- 不继续增加 `visible` 角色或可见页强制 upload；正常预加载应在页面进入视口前完成。
- 不扩大固定静态帧水位；静态页仍只需要一帧。
- 不让 Widget 保存图片字节、decoded frame 或 texture；重资源继续归 Pipeline/Sessions/FrameBudget。
- 不在 source listener 中直接绕过 staged policy 执行任意 decode；保留全局水位顺序，但 source wake 必须持续到真正消费。

## 计划

1. 删除 dev.118 `PageRole.visible` 及其强制 demand/protection。
2. 让未消费 source revision 自动附着到后续 refill；只在 fill 实际完成后标记已消费。
3. 静态 output 失去 demand 后进入 dormant retained 状态；FrameBudget 超限时按无需求最低优先级回收。
4. 纵向轻量 host 使用对称七页保活半径；重资源不受该设置直接保留。

## 实现结果

- `StagedDecodeRefillPolicy` 增加 eligibility lookup；处于 `waitingSource` 且没有未消费 source revision 的页面不再占据全局 refill 决策。
- `LiveCoordinator` 将 source revision 保持到对应 fill 真正执行；重定向后的 source wake 会在后续 refill 自动恢复。
- `UploadSession` 增加权威静态 output 的无需求驻留；`UploadRegistry` 与 `LiveCoordinator` 只在单帧分类完成且已有 output 时采用。
- dormant output 不再由 demand detach 销毁，FrameBudget 在实际超限时按无需求最低优先级回收。
- 删除 `PageRole.visible`、全部可见页强制 demand 和特殊 FrameBudget 保护；可见覆盖仅保留为观察与诊断输入。
- 纵向轻量 host 保留半径调整为七页；ListView cache extent 固定四屏，重资源所有权未进入 Widget。
- Trace 增加 `staticFrameKept` 及 analyzer 统计。

## 设备前基线

对输入 Trace 的 analyzer 统计：21 个 page host dispose，其中 11 个发生在首帧前；没有 `staticFrameKept`。多个页面 source ready 后直到角色提升才解码，作为 dev.119 设备复验对照。
