# zic Implementation Plan

本文件只列未完成工作。

## P0：后台恢复闭环

- 验证新 Reader 命中同一 DecodeId 的 retained output；
- 检查 `retainedOutputRestoreCount`、恢复后的 mount-to-first-frame 和 redraw present；
- 确认 authoritative download/decode 继续并替换恢复帧；
- 验证不同 DecodeId 或超 64 MiB 时不会错误恢复。

## P0：Partial failure 闭环

- 通过可控增长 source 触发 native partial failure；
- 未封缄时只出现 `decode-source-growth`，不出现定时 `decode-recovery`；
- source revision 增长后继续原 cursor；
- sealed corruption 仍进入有界恢复并保留错误可观测性。

## P0：工具链与 Patch

- 运行 Flutter analyzer/tests、Android release 与设备 Trace；
- 从干净 dev.124 验证 patch `git apply --check --index` 和实际 apply；
- 正式 ZIP 必须排除 `.zic-workspace.json`，patch 不得修改用户本地配置。
