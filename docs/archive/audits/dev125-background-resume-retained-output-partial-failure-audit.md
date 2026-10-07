# dev.125 后台恢复与 Partial Decode Failure 审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.124_startup-current-prefix-exact-output-prewarm.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-04T13-33-48.jsonl`。
- VibeVenera 仅作只读参考；其无条件循环策略不进入本轮修改。

## 问题清单

### 后台恢复性能

- 前五次 Reader session 的 mount-to-first-frame 约 232–386 ms；长后台间隔后的两次 session 均约 1.21 s。
- dev.124 精确 output prewarm 已生效：恢复后首帧 `surfaceReconfigureCount=0`、`outputPrepareMicros` 约 0.1–0.2 ms。
- 恢复后首帧 source wait 约 247–264 ms、native decode 约 225–227 ms、platform present 约 226–245 ms，均显著高于后台前。
- Reader session 关闭后，Android texture pool 会保留相同尺寸 lease，插件侧 lease 仍持有最后已呈现 native frame；但 pool 只按尺寸复用，不记录 DecodeId，后续 session 无法把该画面作为恢复 output 使用，仍从 source/decode 重建。

### Partial decode failure

- Rust 对未封缄 WebP 的 libwebp `Failed` 已转换为 `NeedMoreData`。
- Dart native cursor 对 ABI `failed` 仍无 source sealed 判定，可能抛出普通 `StateError`。
- `DecodeSession` 会把普通异常标记为 `DecodeState.failed`；`LiveCoordinator` 对 current/transition 安排 16/32/48/64 ms 的 decode recovery。未封缄 source 的一次 partial decode failure 因而仍可能进入定时恢复链，销毁或重启 cursor，而不是等待下一 source revision。

### 交付与工作区

- `.zic-workspace.json` 是机器本地配置，用户与交付环境的 `patch_dir` 不同；release ZIP 不应包含该文件。
- patch 仍必须兼容 `git apply --index`，但 patch 生成目录应由环境变量或本地配置解析，不得把远端路径写进发行包。

## 所有权清单

| 能力 | 所有者 |
|---|---|
| DecodeId 对应的 retained platform output | `pipeline_native` texture lease pool |
| 把 retained output 投影给 UploadSession | `media` 可选 uploader capability + `sessions/UploadSession` |
| texture redraw 与 SurfaceProducer 生命周期 | `texture_bridge` |
| partial cursor 状态分类 | `bridge` / `sessions/DecodeSession` |
| decode recovery 策略 | `sessions/LiveCoordinator` |
| `.zic-workspace.json` | 用户本地工作区，不属于 release artifact |

## 否决方案

- 不通过缩小 7/3、永久 local=1 或关闭 next 下载掩盖恢复慢。
- 不在 Reader Widget 内缓存图片、NativeFrame 或 texture。
- 不把旧 retained frame 当作新 source revision 的权威解码结果；它只作为同一 DecodeId 的恢复占位，后台解码仍继续并替换。
- 不把所有未封缄异常都无限吞掉；仅 native partial decode 状态与明确的非封缄 decode failure等待 source growth，封缄失败仍进入有界恢复/错误。
- 不修改或复制 VibeVenera 的无条件循环逻辑。
- 不把 `.zic-workspace.json` 写进新 ZIP，也不修改用户本地 `patch_dir`。
