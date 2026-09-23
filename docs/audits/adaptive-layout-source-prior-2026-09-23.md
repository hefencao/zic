# 2026-09-23 自适应布局来源条漫先验审计

## 范围

本轮只调整自适应阅读布局的证据模型与来源级用户先验，不改变 Reader/Pipeline 下载、解码、预取、缓存或 transport ownership。

## 根因

旧的 `AdaptiveReaderClassifier._classifyGeometry()` 继承了早期 VibeVenera 分段规则：`height / width < 1.55` 的页面每个样本固定获得 `paged += 1.5`。这意味着 1:1、接近 1:1 的来源切片会成为最强分页证据；而很多条漫来源会把长幅正文拆成近方形 transport page，因此“切片方式”被错误解释成“横排阅读布局”。

本地 `~/projects/vibevenera/lib/foundation/adaptive_comic.dart` 仍可看到同源旧规则，确认问题来自遗留评分方向，而不是肉漫屋的单源异常。

## 边界

- 自动分类唯一 owner 继续是 `reader_runtime.AdaptiveReaderClassifier`。
- 来源条漫权重唯一持久 authority 是 `AppPreferencesController.sourceAdaptiveWebtoonWeights`，按稳定 `sourceId` 保存。
- App 仅通过 `ReaderSessionSettings.sourceWebtoonWeight` 把值只读投影给 Reader；Reader 不监听、不写回来源设置。
- 不新增 plugin-host 权重、不按“肉漫屋”名称硬编码、不建立插件管理页与来源管理页两份互相覆盖的设置。
- 漫画级显式阅读方向保持最高优先级；来源原始 readingDirection 仍只是 fallback。
- `韩国/韓國/korea` 只作为弱条漫 evidence 进入几何合成，不成为语言分类或直接阅读模式。

## 实现

Adaptive model 升到 v6：

- 近 1:1 页面改为低信息；分页 evidence 使用 `abs(log2(height / width))`，让 16:9 与 9:16 对称地按“离 1:1 有多远”提高分页置信。
- 约 1.9–2.2 的纵向比例保留低置信过渡，更长纵幅逐步增强条漫 evidence。
- 来源条漫权重取值 0–1；0 表示完全自动并从持久 map 中移除，非零值进入评分。
- 非零来源权重进入 adaptive evidence fingerprint；修改来源权重会自然失效旧自动 profile。权重为 0 时维持旧 metadata fingerprint，避免无先验场景产生无意义 identity 变化。
- 来源管理页提供“条漫权重”滑杆；Mihon/Venera 来源均按实际 `sourceId` 使用同一设置 owner。

## 验证

Focused：

- `python3 tool/test_reader_layout_settings_contract.py`：PASS。
- `python3 tool/test_dev83_preload_adaptive_stitch.py`：PASS。
- `flutter test packages/reader_runtime/test/adaptive_reader_classifier_test.dart packages/reader_runtime/test/reader_session_settings_test.dart`：PASS。
- `flutter test apps/app/test/misc_settings_test.dart`：PASS。
- `flutter test apps/app/test/source_browser_test.dart --plain-name 'source management persists adaptive webtoon weight'`：PASS。
- 新回归覆盖 1:1 低置信、16:9/9:16 稳定分页、极长纵幅稳定纵排、`韩国` 弱证据、来源权重 fingerprint 与持久化/UI 编辑。

Repository/toolchain：

- `git diff --check`：PASS。
- `python3 tool/check_documentation.py`：PASS。
- `python3 tool/check_repo.py`：PASS。
- `tool/check.sh`：PASS，exit 0；包含历史 contract、全仓 analyzer、Dart/Flutter tests、Android 三 ABI debug APK build 与 Rust `media_core` 22/22。
- Analyzer 仍报告仓库既有 info 级 lint debt，但本轮无 error/warning。
- 部分 Kotlin/Java helper contract 在当前 WSL 工具链按门禁设计显示 SKIP；完整 `tool/check.sh` 仍为成功。

## 未声称的证据

本轮没有把线上肉漫屋“要成為男子漢”重新拉取并做真机端到端复现，因此不把该具体来源实例标记为 Verified-device。它描述的关键输入组合（近 1:1 页面、`韩国` 标签、来源级条漫先验）已由 deterministic regression 覆盖；实际源数据若还有额外标签/比例分布，可在后续真机 trace 中继续校准权重，而不需要新增第二条判定路径。
