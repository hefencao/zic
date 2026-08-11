# dev.212 验证结果

## 基线与环境

- 唯一代码基线：`zic_v0.31.0-dev.211_version-equivalence-late-artifact-reuse.zip`。
- 当前版本：`0.31.0-dev.212` / Android `versionCode=212`。
- 输入证据：`zic-debug-trace-2026-08-11T02-25-52.jsonl`、`错误报告(20260811-022642).txt`。
- 当前环境有 Python、Git、Kotlin/JVM、Node；没有 Dart/Flutter SDK，因此不宣称 `flutter analyze`、Dart/Flutter tests 或 APK build 已执行通过。
- `check_repo.py` 继续只停止在基线缺失 `third_party/source_archives/libwebp-1.6.0.zip`；本轮未从其它版本补入。

## 编译错误验证

用户本地错误定位 `packages/catalog/lib/src/source_catalog.dart` 的 `ComicVersionPageMapping.fromJson`：`json['verifiedAt']` 静态类型为 `Object?`，原实现把它直接传给 `DateTime.parse`。dev.212 先检查 `String` 类型，再用 `DateTime.tryParse` 严格解析；非法类型与不可解析时间均抛 `FormatException`。新增 catalog regression test覆盖合法时区字符串、数字类型和非法日期字符串。

## 02:25 trace 结论

结构化扫描共 9689 条事件：

- Reader前可恢复3个persistent mappings并登记1113个equivalent pages；`verifiedEquivalentReuse=true` 的 `sourceRead` 有29次，另有29次对应 artifact-source事件，证明dev.211动态equivalence真实命中。
- origin `sourceRead` 共27次、23个唯一DownloadId；与equivalence-hit sourceRead的DownloadId集合交集为0。剩余origin不是“已有相关完整artifact却没复用”的同一缺陷。
- `version-page-mapping-warmed` 共15次，仅5个relation identity，单relation最多重复5次；多数没有新增equivalent page。根因是详情/Reader每次都schedule warmup，而原 `_versionReuseWarmups` 只去重并发，不利用持久 `verifiedAt` 避免短时间重复强identity验证。
- `version-durable-partial-reused` 共8次、累计73个partial；`resumeAccepted` 共7次，其中2次为validatorless range probe。partial reuse已实际工作，本轮不扩大到hot session。
- 仅1条taskFailed，为rhttp取消事件；没有证据指向version mapping/equivalence系统性失败。

## 实现验证

- `verifiedAt` JSON解码改为显式类型收窄 + `DateTime.tryParse` + UTC。
- 新增10分钟 `_versionPageMappingRevalidationInterval`：relation所有mapping均有合法且未过期verifiedAt时跳过 `loadComic + strong page identity` mapping重验证。
- `findComicVersions`仍在每次详情/Reader入口异步执行；新relation、缺verifiedAt、未来异常时间或过期mapping仍重新验证。
- verified-equivalence、exact-first lookup、durable partial复制、DownloadJob overlap验证未改变。

## 实际通过

- `check_dart_structure.py`：347 Dart files / 130 test files。
- Dart directive order、documentation、dev.139 current documentation。
- dev.165、173、207–212相关 ownership gates。
- source-resource atomic binding、Reader streaming、Pipeline demand、UI architecture。
- Venera bootstrap / Reader preflight / network policy。
- Mihon payload Context Kotlin compile、ABI routing、split classloader、chapter contract。
- Android runtime dependency、texture bridge Kotlin compile、native header、Python compile与 shell syntax。

## 候选 Patch 回放

在写入本 validation 文件前，从全新dev.211根目录生成候选Patch并实际执行：

- `git apply --check --index`
- `git apply --index`

候选结果：15个真实修改/新增文件，1290个发行文件，missing=0、extra=0、content diff=0、executable-bit diff=0。

加入本 validation 文件后的第二次候选回放包含16个真实修改/新增文件、1291个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后从全新dev.211重新生成最终Patch并再次执行 `git apply --check --index` / `git apply --index` 与完整file-set/mode比较。最终发行只有在结果仍为1291 / 0 / 0 / 0 / 0时成立。
