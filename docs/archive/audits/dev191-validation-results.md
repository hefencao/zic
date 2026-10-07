# dev.191 验证结果

## 已执行并通过

- `python3 tool/check_documentation.py`
- `python3 tool/check_dart_structure.py`：343 files / 129 test files
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.157–191 release/ownership gates；另补 dev.86、dev.89、dev.135 网络/Cookie/cache identity历史合同
- `python3 tool/test_venera_network_cache_contract.py`：真实使用 `kotlinc`/`java`编译并执行runtime cache helper，验证long/short/no、Cookie header identity和cache header行为
- Node `python3 tool/test_venera_bootstrap.py`：包含plan bridge network logical/cache-hit/origin-call diagnostics
- Venera network policy / response header / native binary / Reader preflight
- source-resource atomic binding、Reader streaming、Pipeline demand stability、UI architecture
- Mihon entry/payload/ABI/classloader/read-only/chapter contracts
- Cloudflare typed classifier Kotlin compile、Android texture bridge Kotlin compile、Android runtime dependency与vertical geometry/trace contracts
- `bash tool/check_native_header.sh`
- `git diff --check`

## 根因覆盖

14:12 dev.190 trace的18个origin样本中，`sourcePlanBridgeNetworkCalls`全部等于4；request-plan中位约3.016s，gate wait中位约1.742s，hook/bridge network中位约1.392s/1.368s。dev.191不修改Reader/NetLane，而在Venera native Network bridge补齐source-requested `cache-time`语义，并剥离`cache-time/prevent-parallel` pseudo headers。新增diagnostics区分逻辑bridge call、runtime cache hit与真实origin call。

当前环境不能实际复现E-Hentai真实origin，因此“后续同gallery resolver GET能命中cache并显著降低真机gate wait”仍需用户设备trace验证；本轮只宣称compatibility contract与helper行为已验证，不宣称真机性能结果。

## 完整 check.sh

实际执行 `bash tool/check.sh`，在第一项因基线继承缺失而退出：

`third_party/source_archives/libwebp-1.6.0.zip`

没有从旧ZIC包或其它基线注入该archive，因此 pinned libwebp host build/smoke不宣称通过。

## 当前环境未验证

- 当前环境没有 Dart/Flutter SDK：analyzer、Dart/Flutter tests和App build未执行。
- Android完整SDK/NDK App debug/release build未执行。
- 真机E-Hentai/Venera resolver cache命中率与性能改善等待下一份设备trace。

## Patch replay

最终候选patch以原始dev.190完整ZIP通过保留Unix mode的`unzip` fresh extract后验证：`git apply --check --index`与`git apply --index`均通过；`.zic-workspace.json`应用前后均不存在；排除`.git`、workspace与Python缓存后，工作树/replay树共1209个文件，内容SHA-256与executable mode逐项一致，无missing/extra/different。验证文本写回后重新生成最终patch并再次fresh replay。
