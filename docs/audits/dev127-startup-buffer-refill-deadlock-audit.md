# dev.127 启动缓冲连续 Refill 死锁审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.126_startup-playback-buffer-deadline-lead.zip`
- 设备 Trace：`zic-debug-trace-2026-08-04T15-00-34.jsonl`

## 问题清单

### 产品

- dev.126 后部分 Animated WebP 只显示 frame 0，随后永久停滞。
- 某些邻页虽然 download/source 已完成，切入前仍未得到首帧，表现为无法加载。

### 调度

- current 启动缓冲目标可能为 4，但首个 staged refill `c>2` 只填充到 3。
- `_runDecode` 完成一个 refill 后调用 `_wakeNextDecodeRefill(except: id)`，明确禁止同一 DecodeId 继续下一阶段。
- 启动缓冲期间 `_nextDecodeRefill` 又只允许 current；排除 current 后没有候选，也没有新的 observation/source 事件必然再次唤醒它。
- 结果是 `playbackBuffering waiting` 没有对应 `ready`。

### 源码卫生

- `live_coordinator.dart` 中静态单帧满足判断存在重复条件行，应清理并加入门禁。

## Trace 证据

- page 5 frame 0：`playbackBuffering waiting`，`successorDepth=0`、`targetDepth=4`。
- 随后 current 仅执行 `c>2`，decode depth 达到 3。
- 该 identity 后续没有 `c>4`、没有 `playbackBuffering ready`、没有 frame 1 presentation。
- output 最终以 `demand-detached` 释放。

## 所有权

- staged refill 与 task chaining：`sessions/LiveCoordinator`。
- 水位阶段定义：`sessions/StagedDecodeRefillPolicy`，不改变。
- 启动缓冲与播放 timer：`sessions/UploadSession`，不迁移所有权。
- Trace 分析：`tool/analyze_frame_pipeline_trace.py`。

## 决策

1. 启动缓冲期间，若下一 staged decision 仍是当前 DecodeId，则在当前 decode lane task 内继续循环执行下一阶段。
2. source-wake 只要求第一次循环必须有未消费 revision；第一次实际 fill 后切换为普通连续 refill，避免第二轮被旧 `sourceWake=true` 提前退出。
3. 达到启动目标、最大 current 水位、terminal/failure 或 demand revision 变化后立即退出。
4. 非启动期仍沿用原有 `_wakeNextDecodeRefill(except: id)`，避免普通页面长期独占 lane。
5. 不删除启动缓冲、不恢复“首帧立即无缓冲播放”，只修其连续补水闭包。

## 否决方案

- 不把目标 4 强行改成 staged 的 3；这会降低约 250 ms 的启动缓冲语义。
- 不依赖 4 ms ticker 周期扫描 decode；ticker 属于播放，不应修补 decode wake。
- 不重新引入可见页强制 decode。
- 不删除 next/next+1 demand；current 达标后正常恢复仲裁。
- 不建立第二套 startup decode 队列。
