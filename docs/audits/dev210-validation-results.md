# dev.210 验证结果

## 基线与输入

- 唯一代码基线：`zic_v0.31.0-dev.209_removed-version-signal-call-closure.zip`。
- 当前候选版本：Source `0.31.0-dev.210`，Android `versionCode=210`。
- 设备证据：`zic-debug-trace-2026-08-11T01-09-52.jsonl`。
- 只读参考：`vibevenera-master.zip`；仅对比版本关系/page-offset/cache alias 时序，不复制其缓存 owner。
- 当前环境有 Python/Git/Kotlin/Node，没有 Dart/Flutter SDK，因此不宣称 `flutter analyze`、Dart/Flutter tests 或 APK build 已执行。

## Trace 根因证据

- Home 服务在约 80 ms ready，冷启动历史/更新封面约 1.05–1.07 s 已出现 first frame。
- 随后直到约 13.956 s 才出现 `version-artifact-alias-prepared`；约 14.075 s 才创建 371 页 Reader session。Reader 创建后约 0.268 s 即产生首帧，并从 persistent artifact读取。这把长时间“无加载/无法操作”定位在 Reader route 创建前的同步版本/alias准备，而不是 Pipeline 首帧性能。
- 同一 trace 中后续版本访问反复出现 `version-artifact-alias-prepared`，说明 dev.209 每次进入相关 Reader仍在现场重新做关系/page identity准备，而不是只恢复持久映射。
- trace 在 Reader dispose时记录多份 durable partial：约 13,967,360 bytes、507,904 bytes、11,970,540 bytes，说明 partial复用具有实际收益；但这些是 durable partial事实，不等于 hot session resume state。

## VibeVenera 对比结论

只读源码对比确认其关键时序为：详情页异步 `findVersions`/page-match warmup；Reader中的版本检查使用 `unawaited`；Reader/loading只恢复已经持久化的 relation/pageOffset并注册临时 alias，不在 Reader关键路径重新联网证明页面身份。dev.210采用相同原则，但继续使用 ZIC现有 `ComicVersionRelationStore`、`ArtifactCacheManager`、`PartialDownloadStore` 和 DownloadId所有权。

## dev.210 结构验证

- `ComicVersionRelation`新增 durable `ComicVersionPageMapping`；SQLite schema升至 8并迁移 `page_mappings_json`。
- 详情页与 Reader入口异步调度版本发现/page identity验证；昂贵 `verifiedPageReuseIdentity`只存在于 background warmup路径。
- Reader前置只调用 `_restoreSourceVersionArtifactReuse`，使用持久 relation + page mapping构造 `VerifiedArtifactReusePlan.fromVerifiedOffset`，不调用 source request-plan。
- 更新 `!` 直接以 relation predecessor raw/canonical identity匹配当前旧版，并明确排除 current successor；不再把版本关系镜像到 `SavedComicRecord.sourceUpdateAt`。
- `applyDurablePartials`只读取 `PartialDownloadStore`可见的 durable inactive partial；目标 partial清空 ETag/Last-Modified。真正续传仍由现有 DownloadJob validatorless overlap probe逐字节验证重叠前缀，失败时走 resume rejection，不让 mapping取代完整性 owner。

## 已通过的可执行检查

- `check_dart_structure.py`：347 Dart files / 130 test files。
- Dart library directive order。
- documentation responsibilities、dev.139 current-code documentation。
- dev.122、dev.135、dev.147、dev.165、dev.173、dev.181、dev.205/206、dev.207、dev.208、dev.209、dev.210相关 ownership gates。
- source-resource atomic binding、UI architecture、Reader streaming、Pipeline demand stability。
- Venera bootstrap/Reader preflight/network/headers相关 contracts。
- Mihon Payload Context Kotlin compile、ABI routing、split classloader、chapter contract。
- Android runtime dependency closure、texture bridge Kotlin compile。
- `python3 -m py_compile tool/*.py` 与 shell syntax检查。

## Repository check

`python3 tool/check_repo.py`只停止在基线继承的 `third_party/source_archives/libwebp-1.6.0.zip` 缺失。本轮未从其它历史包或独立 libwebp包补入。

## 候选 Patch 回放

写入本 validation前，从全新 dev.209项目根目录生成候选 Patch并实际执行：

- `git apply --check --index`
- `git apply --index`

候选工作树/回放树均包含 1282 个发行文件，27 个真实修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。候选没有 executable mode污染。

加入本 validation文件后的完整候选回放包含1283个发行文件、28个真实修改/新增文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后从全新 dev.209重新生成正式 Patch并再次执行 `git apply --check --index`、`git apply --index` 与完整 file-set/content/mode比较。最终发行只有在结果仍为1283 / 0 / 0 / 0 / 0时成立。
