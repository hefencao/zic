# dev.199 验证结果

## 变更边界

- 生产修改仅位于 `packages/sessions`：`DownloadJob`、`DownloadSession`、`LiveCoordinator`。
- 未修改 Reader、Pipeline/Pipeline Runtime、NetLane 核心排序/抢占、downloads bridge/rhttp、Venera/Mihon production代码。
- 新增 `DownloadCatchupDeferred` 只表示 sessions-owned admission defer，不是网络 Failure；`DownloadSession.deferNetwork()` 只允许 queued 状态回到 idle，不修改 artifact/Ingress/epoch。
- 不持久化“endpoint不支持validatorless Range”能力。deferred集合只属于当前 LiveCoordinator 网络任务生命周期；需求升到允许门槛后重新probe。
- 新增 dev.199 gate、ADR 与根因审计；`tool/check.sh` 同时补回 dev.198 gate 调用。

## 回归测试新增

`packages/sessions/test/download_job_test.dart`：

- 大于1 MiB 的 validatorless partial在 Range 被200忽略且 admission拒绝时，必须 discard response、抛 `DownloadCatchupDeferred`、保留 committedLength、回到 idle；
- admission允许时仍重新执行64 KiB probe，并可复用200 response完成 full-body catch-up。

`packages/sessions/test/live_coordinator_test.dart`：

- next2=800 的大 partial发生200 Range-ignore后只允许一次 probe并进入 deferred；
- 随后改成 previous=780，不得重新发网络请求；
- 升为 next=820 后自动解除 defer、重新probe并完成 promotion。

当前执行环境没有 Dart/Flutter SDK，因此这些 Dart 行为测试已写入但不声称已实际运行，也不声称执行了 `dart analyze`、Flutter tests 或完整 Flutter/Android build。

## 已执行静态与合同检查

通过：

- `git diff --check`；
- `python3 tool/check_documentation.py`；
- `python3 tool/check_dart_structure.py`：343 Dart files / 129 test files；
- `tool/test_dart_library_directive_order.py`；
- `tool/test_pipeline_runtime_compile_boundary.py`；
- dev.175–dev.192、dev.195–dev.199现存连续 ownership/release gates；
- dev.195 monotonic playable partial、dev.196 validatorless Range/duplicate traffic、dev.197 semantic trace compaction、dev.198 product-safe endpoint diagnostics、dev.199 cost-aware catch-up admission；
- source-resource atomic/catalog boundary与source-resource binding；
- Reader streaming、Pipeline demand stability、UI architecture；
- Venera network policy/native binary/reader preflight/response headers/source-requested network cache/bootstrap；
- Mihon entry instantiation、payload context、read-only payload、ABI routing、chapter contract、split classloader；
- Cloudflare typed classifier Kotlin compile/behavior；
- texture schedule timing、Android Trace export、Android texture bridge Kotlin compile。

Mihon entry在一组120秒批处理命令中达到执行窗口，随后单独重跑通过；Android texture Kotlin只输出测试stub未使用参数warning。两者均不作为产品失败。

## 完整检查

实际执行 `bash tool/check.sh`，在第一项权威前置依赖检查即退出：

`third_party/source_archives/libwebp-1.6.0.zip`

该 pinned archive 在 dev.198 权威基线中不存在。本轮未从旧版本或其它工作目录补入，因此没有声称完整 `tool/check.sh` 通过。

## Patch replay 与打包

authoritative candidate replay 与写入candidate结果后的 pre-final replay均从原始 dev.198 完整 ZIP fresh extract初始化baseline Git后执行；两轮均满足：

- `git apply --check --index`：通过；
- `git apply --index`：通过；
- 工作树与 replay：1235 / 1235 个有效文件；
- missing=0、extra=0、内容 SHA-256 / executable-mode diff=0；
- ADR0180、dev.199两份 audit 与 dev.199 gate 均实际包含在 patch。

pre-final完整 ZIP用系统`zip`生成、系统`unzip` fresh extract后，与工作树同为1235个有效文件，missing=0、extra=0、内容/executable-mode diff=0；`.git`、`.zic-workspace.json`、`__pycache__`、`.pyc/.pyo`均未进入ZIP。

本审计文本冻结后仍需重新生成最终patch，并执行最后一次fresh dev.198 replay与同冻结树ZIP比对；若最终结果与上述数字不同则不得交付。
