# 2026-09-23 VibeVenera 自适应设置对照与来源条漫置信审计

## 结论
用户指出的语义缺口成立：上一轮 `sourceAdaptiveWebtoonWeights` 只有“中性→更条漫”半轴，不能表达页漫-only 来源。本轮改为单一双向条漫置信：0% 强页漫、50% 中性、100% 强条漫。

同时逐项对照 `~/projects/vibevenera` 的 adaptive comic 实现和 Reader 设置，确认另一个生产遗漏：Vibe source 的 `comic.adaptiveType`、source name/url 在 ZIC classifier 中已有接收/判定代码，但远程插件生产链没有把这些数据送进来。

## 对照矩阵

| VibeVenera 能力 | ZIC 状态 | 本轮处理 |
|---|---|---|
| 全局 Adaptive Comic Type 开关 | 已有 `adaptiveReaderEnabled` | 保留 |
| 漫画级 Use adaptive settings | 已有 `ComicReaderSettings.adaptiveEnabled` 与 Reader sheet | 保留 |
| profile 持久化 | 已有 `ComicReaderSettings.adaptiveProfile` | 保留 |
| 0.60 apply / 0.80 stop | 已有同阈值 | 保留 |
| source `comic.adaptiveType` | classifier 有 `sourceType`，生产链缺失 | 接通 Venera runtime typed hint |
| source name/url 识别证据 | classifier 有 `sourceIdentity`，远程生产链缺失 | App composition 投影 descriptor name/website |
| page geometry | 已有，上一轮 model v6 已修近方形切片 | 保留 |
| decoded animation evidence | 已有，要求真实两页能力证据 | 保留 |
| mixed profile | ZIC 用低置信/无 profile 表达 | 不增加新持久模式 |
| adaptive Reader mode | ZIC profile 已驱动实际方向选择 | 保留现有 owner |
| adaptive long-press zoom | ZIC 有明确用户 zoom 设置 | 不复制 Vibe 隐式改写 |
| animated preload adaptation | ZIC 有 Pipeline-owned prefetch/decode/upload/presentation policy | 不复制第二套策略 |
| translation adaptation | ZIC 无对应 translation feature | 不增加空壳 |

## 双向置信与兼容
新字段为 `sourceAdaptiveWebtoonConfidences[sourceId]`，中性值 0.5 不持久化。classifier 使用 `bias=2*c-1`，对 vertical/paged 分别加入 `+1.5*bias/-1.5*bias`。

旧 `weight=w` 读取时迁移为 `c=0.5+0.5*w`。因此新评分是 `(1.5w,-1.5w)`，旧评分是 `(3w,0)`，两者只差每类共同减去 `1.5w`，softmax 和 mixed score 完全不变。历史用户设置不会因改名发生方向或置信突变。

## ownership
- 持久设置：仅 `AppPreferencesController`。
- plugin 声明：仅 immutable source descriptor capability；Venera 从 source 自身 `comic.adaptiveType` 读取，Mihon 未声明则 null。
- App composition：把 descriptor metadata 与用户来源置信投影到 Reader session。
- Reader：只读消费 `ReaderSessionSettings` + `AdaptiveReaderMetadata`；不保存 source setting，不解析 plugin，不建立第二 classifier。
- 漫画级手动方向仍高于 adaptive 结果；漫画自身明确 tag/动画证据高于来源先验。
- 足够强的用户来源置信高于 provider `adaptiveType`/来源 identity heuristic，因此 0%/100% 能修正来源默认声明，而不是只改弱几何分。

## focused verification
- Reader classifier：覆盖 1:1 低信息、普通比例分页、长幅纵排、韩国弱证据、0% 页漫反证、0/50/100 双向来源置信、configured source type。
- App preferences：覆盖旧 weight→新 confidence 迁移、新 key 覆盖旧 key、0 值页漫持久化、0.5 中性省略和写回删除旧 key。
- Source management widget：覆盖 20% 条漫置信（页漫侧）保存。
- Plugin runtime protocol/adapter：覆盖 typed `SourceAdaptiveReaderType` round-trip 与 catalog descriptor 投影。
- Venera bridge：增加 canonical/alias normalization helper 和 Kotlin unit test；静态 Reader layout contract 锁定 `comic.adaptiveType` → runtime descriptor → Home metadata 路径。

## final verification
- `python3 tool/test_reader_layout_settings_contract.py`：PASS。
- `python3 tool/test_dev83_preload_adaptive_stitch.py`：PASS；历史合同已更新为“composition 可注入 metadata，但 local fallback 必须保留”。
- Reader/App/plugin focused tests：PASS；包括双向条漫置信、旧 weight 迁移、source settings UI、typed runtime descriptor。
- `./gradlew :plugin_host_bridge:testDebugUnitTest --tests dev.zic.pluginhost.VeneraAdaptiveReaderTypeTest`：PASS。
- `git diff --check`、documentation/repository gates：PASS。
- targeted analyzer 无 error/warning；仍只有仓库既有 info 级 lint。
- 完整 `tool/check.sh`：PASS，exit 0。历史 dev.75–338 contracts、全仓 analyzer、全部 Dart/Flutter tests、
  Android armeabi-v7a/arm64-v8a/x86_64 debug APK build、Rust `media_core` 22/22 全部通过。
- 完整门禁中的若干 Kotlin/Java helper 仍按仓库既有环境策略显示 SKIP；本轮新增 Venera adaptive type helper 已由 Gradle Kotlin unit test 单独实际执行通过。

本轮没有重新在线拉取具体肉漫屋漫画做设备端验证，因此不把该实例升级为 Verified-device；
其核心误判条件（近 1:1、韩国弱证据、页漫侧来源置信）已经有 deterministic regression。
