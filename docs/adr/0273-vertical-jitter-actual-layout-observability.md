# ADR 0273：纵排抖动以真实布局观测进入下一归因层

## 状态
Accepted。dev.293 的媒体比例修复继续有效；本 ADR 只定义剩余抖动的观测边界，不新增 layout/presentation owner。

## 触发与纠正
用户在 dev.293 后明确纠正：仍存在的是固定区域/滑动抖动，缩放/比例异常已经在前一轮修复后解决。因此 dev.293 交接中“若 scale 仍异常再继续验证”的当前问题表述失效，不能再把 jitter 与 media-aspect/sourceCanvas/replay 路线混为一谈。

## 已冻结证据
- dev.280/281 已收口 active ratio snapshot 与 idle layout-time correction。
- dev.282 已收口 retained OutputFrame 的 platform resident reuse。
- dev.283 已禁止 vertical `logicalPosition` 虚构 hidden target。
- dev.285 已把 ordinary detach 后的 promoted physical owner 收口为最多 8 个 idle hot tail；若后续 Trace 未重新证明 physical/session-copy churn 与抖动同步，不再扩 retention。
- dev.293 的 `MediaAspectViewport(fitWidth)` 已独立保持 source aspect；用户设备结果确认 scale defect 已闭合。

## 决策
1. dev.294 不修改任何 Reader/Pipeline/texture 行为，仅增加 `pageLayoutSnapshot`。
2. 只采样真实可见纵排 page RenderBox；scroll start/end 强制记录，active scroll 中最多约 10 Hz，避免逐帧 Trace 反过来制造卡顿。
3. 每条事件关联稳定 page identity、current/transition/visible role 与 interaction，并同时记录 `ReaderVerticalGeometry` expected extent、真实 constraints/size/paint/global rect 与 Flutter transform。
4. Trace 是 observation-only：不得回流为 item extent、anchor、target、decode/upload/download、texture 或 retention 决策。
5. 下一次设备归因按层分叉：actual box/transform 变化 -> Sliver/layout；box 稳定但 output/role presentation 变化 -> current/transition projection；两者稳定仍视觉抖动 -> external Texture/SurfaceProducer compositor/frame timing。

## 明确不做
不恢复 dev.286 `presentationExtentAt`/OverflowBox，不扩大 encoded 3/7 或 decode 2/1，不新增 visual compensation，不因缺少新 Trace 再改 hot retention、NetLane 或 media aspect。
