# dev.207 验证结果

## 基线与参考

- 唯一代码基线：文件库 `zic_v0.31.0-dev.206_download-owner-partial-venera-rhttp-resolver.zip`。
- 只读参考：文件库 `vibevenera-master.zip`，仅比较其同源版本 temporary cache-key alias/page-offset证明边界；未复制其CacheManager/Pipeline实现。
- 设备证据：`zic-debug-trace-2026-08-10T14-57-03.jsonl`。
- 当前发行候选：Source `0.31.0-dev.207` / App `0.31.0+207` / Android `versionCode=207`。

## 根因验证

1. 旧版更新提醒：dev.206 `_rememberSourceSuccessors`把`sourceUpdateAt`写入绑定到relation“首次新增”。已持久relation在后续入架/状态流程清掉signal后，再次观察不会恢复，导致旧版卡无`!`。dev.207把relation保存与signal reconcile拆开，并在stored successor存在时也重建缺失signal。
2. 未迁移查看新版重新下载：dev.206 `VerifiedArtifactReusePlan.applyExisting`只在真正迁移执行链调用；exact raw-version“查看”不会准备new DownloadId→old artifact alias。dev.207在进入Reader、artifact lookup之前，根据已确认predecessor relation准备temporary alias。
3. Venera opaque locator：manifest中的`venera-resource:`不能直接证明页面等价。dev.207通过现有source request-plan owner解析强media identity，不读取media body；首/中/末证明bounded offset后才建立alias。
4. 纵向静态回拉：`ReaderView.didUpdateWidget`过去把`pageAspectRatios`异步map变化也接到top-anchor保存/下一帧`jumpTo`。dev.207只取消ratio-driven anchor restore，保留vertical stitch、真实viewport/DPR与显式导航anchor。

## 已执行验证

明确通过：

- `check_dart_structure.py`：347 Dart files / 130 test files。
- `test_dart_library_directive_order.py`。
- `check_documentation.py`、`test_dev139_current_documentation.py`；`ARCHITECTURE.md=420`行、`NEXT_CHAT_HANDOFF.md=79`行、`IMPLEMENTATION_PLAN.md=180`行。
- dev.122 / dev.123 vertical geometry/composition。
- dev.135 stable cache identity。
- dev.147 version UI / progress。
- dev.165 Home update semantics（旧一次性`discoveredNewVersion` gate已迁到confirmed-relation reconcile合同）。
- dev.173 migration/version/update badge ownership。
- dev.205 supersession gate、dev.206 Download-owned partial + Venera rhttp边界、dev.207 version reuse/anchor owner gate。
- Reader layout、Reader streaming、source-resource atomic binding、UI architecture。
- Venera bootstrap / Reader preflight / network policy / response headers。
- Mihon payload Context Kotlin compile、ABI routing、split classloader、chapter contract。
- Android runtime dependency closure、texture bridge Kotlin compile、native header check。
- `python3 -m py_compile tool/*.py` 与全部 shell syntax。

`tool/test_dev118_local_direct_visible_output.py`原先把旧单行`session.recordResume(restarted: true)`源码文本写死；dev.206当前实现已是多参数`recordResume(...)`。本轮只迁移该测试到“调用存在 + restarted:true”当前合同，没有恢复旧DownloadJob行为，迁移后通过。

## 当前环境限制

- 当前环境没有 Dart/Flutter SDK，因此没有实际执行或宣称通过 `flutter analyze`、Dart/Flutter package tests、APK build、真机验证。
- 新增 `artifact_cache_reuse_test.dart`中的resolved-offset/strong-media-identity tests已写入源码，需用户本地Flutter/Dart工具链实际执行。
- `python3 tool/check_repo.py`仍只停止在dev.206基线缺失的`third_party/source_archives/libwebp-1.6.0.zip`；本轮未从旧项目或其它库文件补入。

## Patch 预回放

写入本validation文件前，从原始dev.206 ZIP重新解压建立Git基线，候选Patch实际通过：

- `git apply --check --index`
- `git apply --index`

预回放比较1271个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0；当时Patch包含21个实际修改/新增文件。

加入本validation文件与handoff索引后的候选Patch包含22个实际修改/新增文件；从全新dev.206实际执行`git apply --check --index`/`git apply --index`后，工作树与回放树均为1272个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；正式发行将重新从全新dev.206生成最终Patch并再次完整回放，只有结果仍为1272 / 0 / 0 / 0 / 0时成立。
