# dev.195 验证结果

## 结论

本轮直接从 dev.192 重做，dev.193/dev.194 不作为代码基线。与原始 dev.192 逐文件比较后，生产 Dart 代码只有 `packages/sessions/lib/src/download_job.dart` 与 `packages/sessions/lib/src/download_session.dart` 两处变化；DecodeSession、NetLane、Reader/Pipeline、Venera/Mihon production Dart均未修改。网络 attempt不能降低已提交 playback partial；Range不能证明时使用完整前缀 CRC32 catch-up；matching Ingress restore幂等。

## 已执行并通过

- `git diff --check`
- `python3 -m compileall -q tool`（随后清除生成的 `__pycache__/*.pyc`，不进入交付）
- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 Dart files / 129 test files
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.180–dev.192 连续 release/ownership gates，以及新 `tool/test_dev195_monotonic_playable_partial.py`
- partial/download历史合同：dev.112、115、122、123、125、134、135、175、176、177
- source-resource atomic binding、Reader streaming、Pipeline demand stability、UI architecture、frame-trace analyzer
- Venera network policy、native binary、Reader preflight、response headers、source-requested cache、bootstrap contracts
- Mihon entry/payload/read-only/ABI/classloader/chapter contracts
- shared external login bridge、Android runtime dependency contracts
- Cloudflare typed classifier Kotlin compile/behavior contract
- texture schedule timing与Android texture bridge Kotlin compile contracts
- `bash tool/check_native_header.sh`

Kotlin独立编译仅出现测试stub未使用参数 warning。批量执行在Cloudflare Kotlin段达到单次命令窗口后已拆开单独重跑并通过，未把timeout记作通过或失败。

## 完整检查的已知阻断

实际执行 `bash tool/check.sh`，仍在第一项因 dev.192 基线继承缺失的 `third_party/source_archives/libwebp-1.6.0.zip` 退出。没有从dev.193/dev.194、旧版本或其它工作目录补入该archive。

当前环境没有 Dart/Flutter SDK，因此本轮没有声称运行 `dart analyze`、Dart/Flutter tests或完整 Flutter Android build。新增的 validatorless full-body catch-up、prefix mismatch preservation、idempotent Ingress restore与metadata preservation测试已写入，但必须由用户本地 Dart/Flutter 环境执行。

## Candidate patch replay

候选 dev.192→dev.195 patch 在通过 `unzip` 保留Unix mode的原始 dev.192 ZIP fresh extract 上：

- `git apply --check --index`通过；
- `git apply --index`通过；
- 清除本地验证生成的Python bytecode后，工作树与replay均为1217个有效文件；missing=0、extra=0、content/executable-mode difference=0；
- 新ADR、root-cause audit、validation audit与dev.195 gate均实际包含在patch中。

## Final release replay

包含最终验证审计文本的权威patch已从原始dev.192基线重新生成，并在fresh extract上执行`git apply --check --index`与`git apply --index`；两者通过。replay内的documentation、dev.195 gate、Dart structure（343/129）、directive order与Pipeline compile-boundary继续通过；工作树与replay均为1217个有效文件，missing=0、extra=0、content/executable-mode difference=0。
