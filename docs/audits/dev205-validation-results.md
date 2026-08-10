# dev.205 验证结果

## 变更范围

- DecodeSession：holder-empty cursor restart 在 nonsealed prefix gate 前清除旧 continuation requirement。
- DownloadSession：增加无失败/无promotion的 partial writer `pause()` 生命周期原语。
- LiveCoordinator：增加可选、generic 的 pre-download prepare seam，只在本地 committedLength=0 时执行。
- downloads：新增独立 `PartialArtifactCacheBackend` 与 `PartialArtifactCacheHandoff`；Memory/Persistent ChapterDownloads提供实现，Persistent复用现有 durable DownloadSession/artifact/index owner。
- PipelineReaderSession：route retain异步checkpoint、dispose final drain、网络前restore。
- 文档明确 Venera resolver HttpURLConnection 与最终 rhttp media host replay 的真实边界。

## 已执行验证

通过：

- documentation responsibility；
- Dart structure：345 files / 130 test files；
- Dart library directive order；
- Pipeline runtime compile boundary；
- dev.175–205 连续 ownership/release gates；
- dev.195/196 playable partial / validatorless Range continuity；
- dev.199/200 full-body admission 与 defer lifetime；
- dev.201–204 restart-cost retention 历史边界；
- source-resource atomic binding、Reader streaming、Pipeline demand、UI architecture；
- Android trace export / frame analyzer；
- Venera network policy、source-requested cache、native binary、response headers、Reader preflight、bootstrap；
- Mihon entry/payload/ABI/classloader/read-only/chapter；
- Cloudflare typed classifier Kotlin compile/behavior；
- texture schedule、Android texture bridge Kotlin compile；
- Android runtime dependency 与 native header；
- `python3 -m compileall -q tool`。

当前环境没有 Dart/Flutter SDK，因此新增 `decode_session_test.dart`、`partial_artifact_cache_handoff_test.dart` 与 persistent partial reopen Dart 行为测试均已写入但不得声称执行。完整 `bash tool/check.sh` 已实际运行，仍只在权威 dev.204 基线继承缺失的 `third_party/source_archives/libwebp-1.6.0.zip` 前置检查退出；没有从旧版本补入 archive。

## Replay / package

authoritative candidate replay 与写入 candidate 事实后的 pre-final replay 都从原始 dev.204 完整 ZIP fresh extract 初始化 baseline Git 后实际执行；两轮均满足：

- `git apply --check --index`：PASS；
- `git apply --index`：PASS；
- work/replay：1262 / 1262；
- missing=0、extra=0、SHA-256/executable-bit different=0；
- ADR0187、两份 dev.205 audit、partial handoff源码/测试与 dev.205 gate均实际进入patch。

pre-final ZIP 从同一冻结工作树以系统 `zip` 生成并系统 `unzip` fresh extract；work/package=1262/1262，missing=0、extra=0、SHA-256/executable-bit different=0，`.git`、`.zic-workspace.json`、`__pycache__`、`.pyc/.pyo` 均为0。

本审计文本冻结前执行的 final replay/package 同样取得 work/replay/package=1262/1262/1262，missing=0、extra=0、SHA-256/executable-bit different=0、ZIP禁入项=0。写入本最终事实后，release交付仍必须从原始 dev.204 ZIP 后置再执行一次 fresh replay并重打同一冻结树 ZIP；只有后置复验再次取得相同数字才允许交付。
