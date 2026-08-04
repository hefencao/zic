# ADR 0103：预加载 Source Wake 与静态 Output 驻留

**状态：Provisional**

> Source wake 的“重定向后等待后续全局 refill”执行方式已被 ADR 0104 取代；静态 output 驻留、FrameBudget 回收与删除 visible role 的决定保持。

## 背景

设备 Trace 证明，多个纵向静态页在进入视口前已经完成正文读取并持续拥有 decode/upload demand，但仍停在 `waitingSource`。page 23 的 source ready 到 frame 0 约间隔 6.9 秒，page 25 约间隔 1.1 秒，二者都在角色提升为 transition/current 后才解码。

同时，已呈现静态 output 一旦退出 upload demand 就立即执行 `demand-detached`，因此 FrameBudget 无法根据实际内存决定是否保留。dev.118 增加 `PageRole.visible` 只能在页面已经进入视口后补救，不能修复预加载和过早回收。

## 决策

### Source wake

- 每个 DecodeId 分别记录可用与已消费 source revision。
- staged refill 选择时跳过处于 `waitingSource` 且没有未消费 revision 的页面，避免其阻塞真正已就绪的邻页。
- source wake 被更高优先级 refill 重定向时，原页面的 revision 保持 pending；后续 refill 自动携带该 wake。
- 只有对应 fill 实际执行后才记录 revision 已消费。

### 静态 output

- 权威确认单帧的 output 失去 upload demand 后进入 dormant retained 状态，不立即释放 uploader 或 output。
- dormant output 没有需求优先级；FrameBudget 超限时优先回收，并记录 `pageOutputReleased reason=frame-budget`。
- demand 恢复时复用同一 output，不重新 decode/upload。
- 动画 output、未权威分类 output 和失败 output 仍按原生命周期释放。

### 角色与 host

- 删除 `PageRole.visible` 及全部可见页强制 demand/protection。
- 纵向 observation 的可见覆盖只保留为交互和诊断信息，不改变预加载所有权。
- 轻量 host 以七页半径保留；图片字节、decoded frame、texture 和 output 不归 Widget 所有。

## 未采用

- 继续扩大 visible 特例：页面进入视口后才补救，无法满足预加载定义。
- 固定保留更多静态 output：不同图片尺寸下内存不可控。
- Widget 层缓存图片或 texture：形成第二套资源生命周期。
- source listener 直接绕过 staged policy：破坏 c/n/m/p 的全局顺序。

## 验收

- 已 source-ready 的预加载页不再等待角色提升才产生 frame 0。
- Trace 中出现 `staticFrameKept`；普通角色变化不产生对应 `demand-detached`。
- output 未超预算时滑回直接复用；超预算时由 `frame-budget` 回收。
- 无 `PageRole.visible`，下载窗口仍为前 7 / 后 3。
