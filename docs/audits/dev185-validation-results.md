# dev.185 验证结果

## 已执行并通过

- `tool/check_documentation.py`
- `tool/check_dart_structure.py`：343 个 Dart 文件 / 129 个 test 文件结构通过
- `tool/test_dart_library_directive_order.py`
- `tool/test_pipeline_runtime_compile_boundary.py`
- dev.174–dev.185 release/ownership gates，其中包含 dev.185 adjacent-previous normal-pressure gate
- 与 Reader/NetLane 历史语义直接相关的 dev.79/80/82/83/91/93/96/99、dev.110–128、dev.131/132、dev.137/138 gates
- dev.157–dev.173 ownership/source-resource/runtime gates
- test quarantine、texture schedule、frame trace、vertical geometry、Android runtime dependency、Venera network/bootstrap、Mihon chapter、source-resource binding、Reader streaming/UI architecture contracts
- `tool/check_native_header.sh`（通过 `bash` 执行）
- `git diff --check`

新增 Dart 行为回归已写入源码，但当前环境没有 Dart/Flutter SDK，因此没有伪报 `dart test`、Flutter analyzer/build 已执行通过。

## `tool/check.sh`

已真实执行，退出码 1。它在第一项 `check_repo.py` 被 dev.184 基线继承的缺件阻断：

`third_party/source_archives/libwebp-1.6.0.zip`

本轮没有从旧 ZIC 包或其它临时目录偷补该 pinned archive，因此 `tool/check.sh` 后续步骤没有被该命令继续执行；与其独立的相关 Python/static contracts 已按上节逐组执行。

## 工具链可用性

- Node.js：可用，Venera bootstrap contract 已通过。
- cmake / ninja：可用，但 pinned libwebp archive 缺失，因此 source-build 检查不能完成。
- Dart / Flutter：当前环境未安装，Dart/Flutter行为测试、analyzer和 Android Flutter build 未执行。

## Patch replay

已在全新 dev.184 ZIP 解压副本中真实执行：

1. `git apply --check --index`：通过
2. `git apply --index`：通过
3. replay tree 与 dev.185 工作树比较：**1184 个文件逐文件 SHA-256 完全一致**
4. `.zic-workspace.json`：应用前不存在，应用后仍不存在

最终交付 patch 在写回本验证记录后重新生成，并再次执行同样 clean replay：1184 个文件仍全部一致，`.zic-workspace.json` 仍为应用前后不存在，避免“验证的是旧 patch、交付的是新 patch”。
