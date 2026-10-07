# dev.189 验证结果

## 已执行并通过

- `git diff --check`
- `python3 -m compileall -q tool`
- documentation responsibilities
- Dart structure：343 files / 129 test files
- Dart library directive order
- Pipeline runtime compile boundary
- dev.75–97、99–189 release/ownership gates；dev.98未执行，因为其前置 pinned libwebp archive在当前基线缺失
- Venera network policy / native binary / response headers / Reader preflight
- source-resource atomic binding
- Reader layout / Pipeline demand stability / Reader streaming / UI architecture
- Mihon entry / payload / ABI / classloader / read-only / chapter contracts
- external login/settings、Cloudflare classifier Kotlin compile
- texture schedule / Kotlin compile、frame trace analyzer、vertical geometry/cover trace
- Android runtime dependency / trace export contracts
- Node `tool/test_venera_bootstrap.py`，包含新增 request-plan bridge-network timing 与既有5秒delay cancellation行为验证
- `bash tool/check_native_header.sh`

批量 Kotlin 合同两次因单次命令执行窗口到期而中止；未完成的项随后逐项重新执行并通过，不能把批量超时记为产品失败。

## 完整 check.sh

实际执行 `bash tool/check.sh`。第一项 `tool/check_repo.py` 仍因 dev.188基线继承缺失而退出：

`third_party/source_archives/libwebp-1.6.0.zip`

没有从旧ZIC包或其它基线注入该archive，因此 pinned libwebp host build/smoke不宣称通过。

## 当前环境未验证

- Dart/Flutter SDK不存在，因此本轮新增 Dart owner tests、Flutter tests、analyzer与App build未执行，不宣称通过。
- Android完整SDK/NDK App debug/release build未执行。
- 真机行为仍需用户使用dev.189验证。

## 下一份真机trace判据

1. 780↔900 transition抖动不应再造成Venera plan cancellation；只有等待中的任务真正跨入current=1000才允许动态preemption。
2. `sourcePlanGateWaitMicros`若主导 `sourceRequestPlanMicros`，说明主要瓶颈仍是single-invocation排队/临界区。
3. `sourcePlanHookMicros`高而 `sourcePlanBridgeNetworkMicros`低，说明主要是插件hook计算/其它await；若二者接近且bridge calls>0，则主要是EHentai resolver类hook网络。
4. `sourceHostOpenMicros`只有重新成为主要占比时，才继续追rhttp/DNS/TLS/CDN首包。
5. current/previous外层NetLane admission应继续保持dev.185后的毫秒级，不再调整780/1000、5路并发或7/3窗口。

## Patch replay

最终候选patch从原始dev.188完整包重新解压的干净副本验证：

- `git apply --check --index`：通过；
- `git apply --index`：通过；
- `.zic-workspace.json`：应用前后均不存在；
- 排除`.git`、Python缓存与workspace文件后，dev.189工作树与replay树共1200个文件，内容SHA-256与可执行mode逐项一致，无missing/extra/different。
