# ADR 0105：静态单帧满足现有水位

**状态：Provisional**

## 背景

dev.120 通过定向 source wake 修复了预加载页无法获得执行机会的问题，但 refill 仲裁仍可能在媒体分类和 demand replan 的短暂间隙中看到旧的 current 动画水位。权威静态页已经拥有唯一一帧时，继续以 c/n/m/p 目标参与 refill 没有意义，并可能压制混合章节中的动画邻页或静态预加载页。

## 决策

不拆分静态与动画 refill 状态机，也不建立静态专用 scheduler。

在现有 `StagedDecodeRefillPolicy` 增加 `satisfiedOf` 判断：

- animation metadata 已完整；
- `frameCount <= 1`；
- holder depth 与已准备/呈现 output depth 合计至少为 1；

满足时，该 DecodeId 对当前 demand 视为水位已满足，跳过 `one>0` 和所有 c/n/m/p 阶段。动画页仍按原有 staged waterline 运行。

## 取舍

该判断允许 demand replan 存在短暂异步时序，而不会让静态页按旧的高水位重复抢占 decoder。若静态 output 和 holder 都已被预算回收，满足条件自然失效，页面可以重新解码一帧。

## 未采用

- 静态/动画两套状态机：增加重复仲裁和混合章节复杂度。
- 分类后强制把所有 demand 永久改为 1：不能处理 output 被回收后需要重建，也放大 replan 时序耦合。
- 保留 dev.120 定向 wake 作为唯一修复：只能保证执行机会，不能表达静态一帧已经完成。

## 验收

- 静态 current 已有一帧时，不再产生 c/n/m/p refill；
- 动画 neighbor 仍可按自己的 staged waterline 补水；
- 静态 output 被实际回收后，可重新执行 one-frame decode；
- 不新增媒体类型专用 lane 或状态机。
