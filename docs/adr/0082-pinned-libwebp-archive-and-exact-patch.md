# ADR 0082：锁定 libwebp 离线归档与精确补丁准备链

- 状态：Accepted
- 版本：`0.31.0-dev.98`
- 日期：2026-08-03
- 取代/修正：ADR 0081 第 6 项的函数锚点 transformer；ADR 0080 第 4 项的 source/patch 准备实现。播放 runtime 决策不变。

## 背景

用户明确提供文件库中的 `libwebp-1.6.0.zip`。dev.96 的 compact patch 并非按该真实文件布局生成，GNU patch 在本地表现为前两个 hunk fuzzy 成功、第三个 hunk 因布局/换行失败；临时脚本又只检查任一 token，可能把 partial patch 当成等价实现。dev.97 改为函数锚点 transformer，但回归只覆盖缩小 fixture，并继续允许从可变 `.deps/src/libwebp-1.6.0` 复制，遇到已有差异时会报误导性的 `VP8Clear anchor found 0`。

## 决策

1. 将文件库的精确 `libwebp-1.6.0.zip` 保留为 `third_party/source_archives/libwebp-1.6.0.zip`。`native/libwebp.lock` 锁定 archive SHA-256、上游 commit 和干净 `src/dec/vp8_dec.c` SHA-256。
2. `fetch_webp.sh` 是 upstream source cache 的唯一所有者。默认从保留归档离线、安全解压到按 archive hash 命名的 `.deps/src/upstream/`；发现 cache 漂移时直接从归档重建。`ZIC_WEBP_SOURCE` 只有在关键源文件 hash 精确匹配时才进入正式构建；git 仅在归档不存在时作为 pinned fallback。
3. upstream tree 永不原地 patch。`prepare_webp.sh` 复制干净 tree 到临时 prepared tree，删除 source marker/git metadata，只规范化目标 C 文件换行。
4. `libwebp-vp8-thread-buffer-pool-v1.6.0.patch` 必须由保留归档的真实 v1.6.0 文件生成。准备脚本先运行 `patch --dry-run --batch --forward --fuzz=0`；全部 hunk 成功后才实际应用。失败不得留下 `.rej`、`.orig` 或部分修改。
5. `verify_libwebp_vp8_tls_patch.py` 独立验证 TLS 声明、`VP8New` acquire、`VP8Clear` largest-buffer return、顺序和唯一性，并拒绝额外 `VP8MemPoolAcquire/Return` 或 `WebPSetWorkerInterface`。
6. 删除无生产调用且已证明脆弱的 `apply_libwebp_vp8_tls_patch.py`。不得以新名字恢复函数文本锚点、fuzzy patch 或 token-presence fallback。
7. prepared identity 使用 commit、干净 source SHA 与 patch SHA。host/Android build 在保留归档存在时不要求 git；其余 CMake、Ninja、NDK 和产物所有权不变。

## 被否决方案

- 继续联网 fetch 作为唯一验证路径：忽略用户已提供的精确源码，且离线环境无法复现。
- 对 unknown/mutated source 继续尝试 transformer：会把 source drift 误报为某个函数锚点缺失。
- patch 失败后只 grep 任一 TLS/mempool token：可能接受仅应用一部分 hunk 的不可用 tree。
- 使用 patch fuzz：会在版本或布局漂移时把修改应用到未经审计的位置。
- 原地修改 upstream cache：污染下一次 prepared build，破坏 source 与 local patch 的所有权边界。

## 后果

- bare `bash tool/prepare_webp.sh` 在项目 ZIP 中可离线、确定性准备同一 v1.6.0 tree。
- 项目 ZIP 增加约 6.8 MB 官方 source archive，但不包含其展开目录或构建产物。
- source drift 会在 patch 前以 hash mismatch 明确失败；正常路径不再出现 `VP8Clear anchor found 0`。
- Runtime 性能模型、线程模型与 Reader/Pipeline 状态没有变化。
