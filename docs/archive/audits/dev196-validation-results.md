# dev.196 验证结果

## 结论

本轮以 dev.195 完整 ZIP 为唯一基线，修改面只覆盖 validatorless resume continuity、rhttp 合法206中段的媒体头校验边界与只读重复流量诊断。dev.195 的 playable-partial authority 与幂等 Ingress restore保持；DecodeSession、Reader/Pipeline、NetLane、Venera/Mihon production code不参与本轮策略修改。

相对 dev.195 的 production Dart 修改仅有：

- `packages/sessions/lib/src/download_job.dart`；
- `packages/sessions/lib/src/download_session.dart`；
- `packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart`。

## 行为合同

新增/调整 `packages/sessions/test/download_job_test.dart`：

- strong-validator Range被完整200 response拒绝时复用同一response，不再 discard + 再开full request；
- validatorless partial在totalLength已知时只发一个最多64KiB overlap Range，且validators不伪造；
- Range支持时逐字节验证overlap后从旧boundary继续；
- Range被忽略返回200时同一个response直接进入full-prefix CRC catch-up，request数仍为1；
- overlap mismatch继续保留旧partial/epoch。

当前环境没有 Dart/Flutter SDK，因此这些 Dart tests 已写入但不能声称已执行通过。

## 已执行验证

通过：

- `python3 -m compileall -q tool`；
- `python3 tool/check_documentation.py`；
- Dart structure：343 files / 129 test files；
- Dart library directive order；
- Pipeline runtime compile boundary；
- dev.175、176、177、180–192、195、196相关 ownership/release gates；
- dev.178 rhttp startup transport、dev.182 rhttp single-framing、dev.192 transfer-stage observation；
- source-resource atomic binding / dev.162 catalog boundary；
- Venera Network cache、network policy、native binary、response headers、Reader preflight、bootstrap；
- texture schedule contract与Android texture Kotlin compile；
- Mihon entry、payload Context、ABI、classloader、read-only、chapter contracts；
- Pipeline demand stability、Reader streaming、UI architecture；
- Cloudflare classifier Kotlin compile；
- native header check；
- `git diff --check`。

一次平台批跑在 Mihon payload、随后另一批在 Venera response header附近达到单次执行窗口；相关项均拆开重新执行并通过，未把 timeout 当成产品通过或失败。

## 完整 check

实际执行 `bash tool/check.sh`，仍在基线继承缺失的 `third_party/source_archives/libwebp-1.6.0.zip` 第一项退出，返回码1。没有从旧版本或其它工作树补入该 archive。

环境可用 `kotlinc`/Java，但没有 `dart`/`flutter`，因此没有声称 `dart analyze`、Dart package tests、Flutter tests或完整Android Flutter build通过。

## Patch replay / package

已从原始 dev.195 完整 ZIP 使用 `unzip` 做两轮独立 fresh replay。两轮都先初始化 baseline index，再执行 `git apply --check --index` 与实际 `git apply --index`，均通过；逐文件 SHA-256 与 executable bit 比较均为 work 1221 / replay 1221，missing=0、extra=0、different=0，`.zic-workspace.json` 在应用前后均不存在。

本审计文本锁定前的候选 dev.196 完整 ZIP 已独立解压比较：work 1221 / package 1221，missing=0、extra=0、different=0。随后基于锁定后的审计文本重新生成 release patch并再次 fresh replay，仍为 work 1221 / replay 1221，missing=0、extra=0、different=0；最终 release ZIP 重新打包解压后同样为 work 1221 / package 1221，missing=0、extra=0、different=0。最终 ZIP 不含 `.git`、`.zic-workspace.json`、`__pycache__` 或 `.pyc`。
