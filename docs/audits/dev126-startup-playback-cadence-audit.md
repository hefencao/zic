# dev.126 启动播放节奏审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.125_background-retained-output-partial-source-growth.zip`
- 设备 Trace：`zic-debug-trace-2026-08-04T14-25-45.jsonl`

## 问题清单

### 产品

- Reader 首帧已在约 50–385 ms 内出现，但 Animated WebP 前几秒明显卡顿。
- Flutter DevTools 未出现对应 build/raster 超时，因为卡顿发生在 native decode、MethodChannel、Surface blit 与播放 deadline 之间。

### 性能

- 30 fps 页面 nominal duration 约 33 ms，实际可见帧间隔中位数约 54–69 ms，并夹杂 100 ms 以上停顿。
- native decode 约 54 ms/帧；首批 platform present 约 55–99 ms，后续降至约 4–10 ms。
- 旧调度在 deadline 到达后才请求 successor upload/present，实际间隔额外叠加 ticker 与 present 成本。
- frame 0 呈现后立即启动 playback，current 7 帧缓冲尚未建立。

### 架构

- `UploadSession` 拥有播放 timer 与 output lifecycle，应在该层决定启动缓冲和 deadline lead。
- `LiveCoordinator` 只在启动缓冲期间限制 decode refill eligibility，不建立第二套队列或改变水位。
- Reader、Widget、texture bridge 不拥有播放策略。

## 否决方案

- 不把卡顿伪装成 Flutter UI jank。
- 不扩大长期 current 水位，不缓存 30 帧 RGBA。
- 不降低稳定播放速度或修改 WebP 帧时长。
- 不关闭 next/next+1 预解码；只在 current 启动缓冲未满足时暂缓。
- 不在 Reader Widget 中增加 timer、frame queue 或 texture cache。
