# dev.213 验证结果

## 基线与环境

- 唯一代码基线：`zic_v0.31.0-dev.212_version-mapping-decode-freshness.zip`。
- 只读参考：文件库 `vibevenera-master.zip`。
- 设备证据：`zic-debug-trace-2026-08-11T03-35-42.jsonl`。
- 当前环境有 Python、Git、Kotlin/JVM、Node；没有 Dart/Flutter SDK，因此不宣称 `flutter analyze`、Dart/Flutter tests或 APK build已执行通过。
- `check_repo.py`仍只停止于基线继承的 `third_party/source_archives/libwebp-1.6.0.zip` 缺失；未从旧包补入。

## Trace 与 VibeVenera 结论

- 压力trace共5392条事件，存在4个重叠Reader：371页、377页、371页、377页。
- `version-page-mapping-warmed`共18次/5个relation identity，单relation最多6次；dev.212 stale mapping内部按页数相同直接continue，过期mapping没有真正strong revalidate/刷新verifiedAt。
- full equivalence并非整体失效：7条 `sourceRead` 明确 `verifiedEquivalentReuse=true`。
- checksum对齐得到至少3组不同DownloadId最终下载出完全相同内容。17,572,068 bytes / checksum `61d36554` 的一组尤其关键：一侧full约96.65s已完成并随后进入persistent cache；另一侧后来从6,062,080-byte durable partial恢复，却仍走origin Range并再次下载得到同一checksum。这证明压力测试中的重复流量不能全部归因于“mapping尚未完成”。
- VibeVenera源码确认：`aliasImage()` 在 `_downloadIdentity()` 前解析；`DownloadSessionRegistry`、`ImageDownloader._loadingImages` 与 `_PartialImageCache(cacheKey)`因此可落到同一逻辑下载identity，具有共享in-flight/session partial的效果。ZIC目前各 `PipelineReaderSession`拥有独立DownloadRegistry/SourcePool；直接照搬需要跨Reader共享writer及取消/priority/retention/decode source协议。

## dev.213 实现验证

- `ArtifactCacheManager.storePromotedArtifact()`只有在backend权威store与memory remember完成后才通知promotion listener；observer异常不能破坏artifact commit。
- `PipelineReaderSession`只对自己registry中已物化的direct verified-equivalent DownloadId响应promotion，并在dispose前移除listener。
- `LiveCoordinator.refreshDownloadForLocalArtifact()`保留committed prefix，不reset DownloadSession；cache-resident目标不takeover；local immutable full事实清除旧network retry/terminal/defer记忆。queued attempt重排、active attempt取消后沿原finally在同demand下重新open。
- ArtifactCacheTransport的origin/cache trace输出 `verifiedEquivalentCandidates`，供下一轮区分mapping缺边与候选full尚未出现。
- stale `ComicVersionPageMapping`页数即使未变也必须重新进入 `matchResolvedRelated` strong验证；只有单mapping自身fresh时可跳过。成功mapping由现有helper写入新的UTC `verifiedAt`。
- 未实现跨Reader `shareSessionPartial` / `aliasDownloadSession`；durable inactive partial规则保持dev.210。

## 实际通过

- `check_dart_structure.py`：347 Dart files / 130 test files。
- `test_dart_library_directive_order.py`。
- documentation responsibility + dev.139 current-code documentation。
- dev.135、dev.165、dev.173、dev.205历史partial合同、dev.206、dev.207、dev.208、dev.209、dev.210、dev.211、dev.212、dev.213 owner gates。
- source-resource atomic binding、Reader streaming、Pipeline demand、UI architecture。
- Venera bootstrap / Reader preflight / network policy / response headers。
- Mihon entry、Payload Context Kotlin compile、ABI routing、split classloader、chapter contract。
- Android runtime dependency、texture bridge Kotlin compile。
- `python3 -m py_compile tool/*.py`、`bash -n tool/check.sh`。

## 候选 Patch 回放

写入本validation文件前，从全新dev.212项目根目录生成候选Patch，并实际执行：

- `git apply --check --index`
- `git apply --index`

候选Patch包含19个真实修改/新增文件；工作树与replay树均为1294个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0。未发现mode污染。

加入本validation后的候选回放包含20个真实修改/新增文件、1295个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后从全新dev.212重新生成最终Patch并执行最后一次 `git apply --check --index` / `git apply --index` 与完整file-set/mode比较。最终发行只有在结果仍为1295 / 0 / 0 / 0 / 0时成立。
