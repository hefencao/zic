# dev.211 验证结果

## 环境与基线

- 唯一代码基线：`zic_v0.31.0-dev.210_version-mapping-reader-fast-partial-reuse.zip`。
- 当前发行版本：Source `0.31.0-dev.211`，Android `versionCode=211`。
- 设备证据：`zic-debug-trace-2026-08-11T02-00-30.jsonl`。
- 当前环境有 Python、Git、Kotlin/JVM、Node；没有 Dart/Flutter SDK，因此不宣称 `flutter analyze`、Flutter/Dart tests 或 APK build 已执行通过。
- 基线继续缺少 `third_party/source_archives/libwebp-1.6.0.zip`；`check_repo.py` 仅在该既有缺件处停止，未从其它版本补入。

## Trace 结论

- 首次打开 371 页旧版时没有持久 mapping，Reader 立即创建；后台随后开始产生 `version-page-mapping-warmed`。说明 dev.210 Reader fast path 已成立。
- 再次打开同一 371 页旧版前已明确存在 `persistentMappings=3`，但快照式 `version-artifact-alias-restored` 只得到 `reusedPages=13`。
- 相关 377 页 Reader 在旧版 Reader 重开后仍继续运行并在之后才 dispose；因此它在 alias 快照之后继续完成新的 immutable artifact，这些迟到 artifact 无法被 dev.210 已经结束的 `applyExisting()` 扫描自动看到。
- durable partial 复用已经实际发生，双向分别出现 `reusedPartials=50` 与 `reusedPartials=6`，因此本轮不扩大到 hot-session partial。

## dev.211 修复边界

- `ArtifactCacheManager` 新增 bounded verified-equivalence registry。page mapping 一经确认即可登记 DownloadId 等价关系，不要求任一侧当时已经有完整 artifact。
- 普通读取严格执行 exact/hard-alias first，只有 exact miss 才查询直接 verified equivalent candidate；以后相关版本迟到 promote 的完整 artifact可立即被读取。
- equivalence 只属于 read fallback：`containsBackend`、`lookupAuthoritative`、`rekey` 和 durable promotion ownership 不得把 equivalent artifact 当成当前 DownloadId 的 exact durable artifact。
- `VerifiedArtifactReusePlan.registerEquivalences()` 取代 Reader 路径中的 snapshot-only `applyExisting()`；mapping warm 后也立即登记 equivalence。
- partial 路径保持 dev.210：只复制 verified mapping 下的 durable inactive prefix，hot session/cursor 不共享，跨版本 validators清空，真正续传仍由 DownloadJob overlap probe验证。

## 实际通过的门禁

- `check_dart_structure.py`：347 Dart files / 130 test files。
- `test_dart_library_directive_order.py`、`check_documentation.py`、`test_dev139_current_documentation.py`。
- dev.135、165、173、205、206、207、208、209、210、211相关 ownership gates。
- source-resource binding、Reader streaming、Pipeline demand、UI architecture。
- Venera bootstrap / Reader preflight / network / response headers。
- Mihon Payload Context Kotlin compile、ABI routing、split classloader、chapter contract。
- Android runtime dependency、texture bridge Kotlin compile、native header。
- `python3 -m py_compile tool/*.py` 与全部 `tool/*.sh` shell syntax。

## Repository check

`python3 tool/check_repo.py` 只停止于基线继承的 pinned libwebp archive 缺失，没有发现新的 repository error。

## Patch 预回放

写入本文件前，从全新 dev.210 项目根目录生成预 Patch并实际执行：

- `git apply --check --index`
- `git apply --index`

预回放包含 22 个真实修改/新增文件、1286 个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0。

加入本 validation 文件后的候选回放包含 23 个真实修改/新增文件、1287 个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后重新生成正式 Patch并从全新 dev.210再次执行 `git apply --check --index` / `git apply --index` 与完整 file-set/content/mode 比较。最终发行只有在冻结结果仍为 1287 / 0 / 0 / 0 / 0 时成立。
