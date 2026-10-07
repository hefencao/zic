# ADR 0157：Current 在饱和 Handoff 下的连续抢占所有权

状态：Accepted
版本：0.31.0-dev.174

## 背景

Reader/Pipeline 已经把 current priority、active priority migration、per-source bucket和一个临时 handoff slot收在 composition-owned `NetLane`。设备现象仍显示：快速翻页后 current有时必须等待其它预下载线程自然结束。

本轮只读对照文件库权威 `vibevenera-master.zip`。两边的基本参数与思路相同：normal network并发、current高优先级、低优先级 active preemption、`max+1` 单一 handoff；差异发生在 handoff 已被一个尚未退出的取消任务占用时。

## 根因

ZIC `_pump()` 先构造 `eligible`。高优先级 pending在 `running >= maxActive + reservedHighPrioritySlots` 时直接被排除；若因此没有 eligible任务，循环立即 `break`。因此新的 current甚至不会调用 `_preemptLowestRunningFor`，必须等某个 running task自然结束/取消完成后才再次调度。

VibeVenera在相同饱和状态仍会对队首 high-priority任务调用一次最低 rank preemption，然后返回等待真实任务退出。它不提前释放 permit，但会持续推动低优先级传输退出，使后续 current无需等待无关 prefetch自然下载完成。

## 决策

1. `NetLane`仍是唯一 network scheduler；Reader/App不得增加抢占逻辑。
2. 当本轮 `_pump` 无任务可立即 admission 时，查找最高优先级、达到 high-priority threshold且确实因 lane/bucket饱和需要 handoff 的 pending task。
3. 对该 blocked current调用既有 `_preemptLowestRunningFor`。victim规则不变：必须 preemptible、尚未 cancelled、同 bucket（当 source bucket已满）且满足 priority差阈值。
4. 该调用**只发取消请求**。blocked current不能在 `running >= max+reserved`时直接启动。
5. active/bucket计数继续只在原 task的 async执行真正 `whenComplete`后释放；禁止“发出 cancel就先减计数”。
6. 不修改 network=5、reserved=1、current=1000、preemption threshold=40、7/3或 holder/decode水位。

## 回归场景

真实 lane规模 5+1：五条 prefetch先占满；current-a取消最低 rank并用唯一 handoff启动。第一个 victim收到 cancel后故意保持未完成。此时提交 current-b：它必须继续取消第二条低 rank prefetch；第二 victim真实退出后，调度器仍有其它低 rank victim可供正常 handoff preemption，从而启动 current-b，而 first victim/current-a都无需先完成。

## 非目标

- 不提前释放底层 transport permit。
- 不把 reserved slot扩成多个。
- 不增加 network concurrency。
- 不在本轮泛化新的 transport cancel API；若设备 trace证明某一 source transport收到 cancel后自身长期无法退出，应沿该 transport生命周期单独审计，而不是再次修改 lane资格。
