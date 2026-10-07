# dev.110 分阶段水位与 last frame 审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.109_cache-tier-native-build-identity.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-03T16-26-05.jsonl`。
- 用户水位模型：c/n/m/p/l，last=keep，按 3/5/7 与 1/2/3/5 分阶段 refill。

## 问题清单

### 产品

- 页面 15 已有 output、frame 37 和 present claim，但页面 14 稳定为 current 后 revision 4 把 upload 从 2 降为 1，并以 `demand-detached` 释放页面 15；纵向布局因此出现旧页区域永久黑屏。
- last 仅暂停不够：current→last 时已有 pending/active upload 仍可能替换原有帧；last→current 又缺少显式 resume。
- `last` 被跳过后，旧窗口没有继续向外寻找独立 previous 槽，p 水位消失。

### 性能

- native texture 已恢复：310 条 frame timing 全部为 platform，当前主导项多为 native decode。
- Reader 1 首次 mount 到 `firstFrameReady` 约 1.42 秒；frame 0 已约 0.70 秒完成 platform presentation，但 first-ready 直到后续帧才发布。
- `PipelinePageOutputStream` 每个新 ready frame 递增 generation，导致正在呈现的第一帧结果被后续帧作废。
- DecodeSession 原来必须完成整个 target fill 后才唤醒 upload；提高 c 水位会反而推迟 frame 0。
- Reader 2 coordinator dispose 仍有约 5.67 秒长尾，但本轮优先修复可见首帧和 last output；保留为后续开放问题。

## 所有权清单

| 状态 | 所有者 | 修改 |
|---|---|---|
| c/n/m/p/l 角色和 maxima | `pipeline` | `last`/`next2`、独立槽位、max watermarks |
| 实际 refill 顺序 | `sessions` | `StagedDecodeRefillPolicy` |
| last pause/keep/resume | `sessions.UploadRegistry/LiveCoordinator` | cancel active upload、freeze、保留 output、resume |
| output budget | `sessions.FrameBudgeter` | current/transition/last output 保护 |
| 首 Surface 发布 | `pipeline_runtime.PipelinePageOutputStream` | 单 in-flight + pending latest |
| 设备诊断 | `telemetry` + analyzer | `decodeRefill`、`lastFrameKept` |

## 被否决方案清单

- 在 Reader Widget 保存 bitmap 代替 session output。
- last 继续维持 download/decode 水位。
- c/n/m/p 同时提交高水位。
- 把 transition 作为表外额外水位。
- 等 c 达到 4 才开始首帧 upload。

## 未验证

当前环境没有 Flutter/Dart SDK、Android toolchain 或设备；dev.110 行为尚未真机复验。
