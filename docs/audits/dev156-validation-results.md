# dev.156 验证结果

## 已完成

- 唯一基线：`zic_v0.31.0-dev.155_cloudflare-real-ua-history-plugin-recovery.zip`。
- 根因审计与 ADR 0141：Reader progress persistence、Mihon chapter API、artwork raw/canonical identity 与唯一 resource gateway。
- 文档职责、Dart 结构、library directive order、Pipeline compile boundary、test quarantine。
- `tool/test_dev156_reader_progress_mihon_chapter_artwork_identity.py` 专项 ownership gate。
- 历史 `test_dev*.py` 共 81 个；除 dev.98 因唯一基线缺少锁定 `third_party/source_archives/libwebp-1.6.0.zip` 外，其余 80 个均通过。对 dev.79、dev.84 等把已被根因证据否决的旧封面分流/章节猜测写死的门禁，已更新为当前所有权合同，没有恢复旧产品行为。
- Android runtime dependency、Trace、texture schedule/bridge、shared network browser、Cloudflare classifier、external source settings/login。
- Mihon entry、payload Context、ABI routing、split classloader、read-only APK staging、chapter catalog contract。
- Venera network policy、native binary、response headers、Reader preflight、bootstrap。
- source-resource binding、Reader layout、Pipeline demand、Reader streaming、UI architecture、native header。
- Python `tool/` compileall 与 shell syntax 检查；生成的 `__pycache__` 已删除。

## Patch 回放

- 在另一份全新 dev.155 临时 Git 基线执行 `git apply --check --index` 与 `git apply --index`。
- 应用后 1064 个发行文件与工作树逐文件内容一致，执行位一致。
- 测试用 `.zic-workspace.json` 应用前后 SHA-256 不变；Patch 不携带或修改工作区配置。
- 回放树再次通过 documentation、Dart structure、directive order、Pipeline compile boundary、dev.155/dev.156、Mihon chapter 与 source-resource 合同。

## ZIP 独立复验

- 候选 ZIP 根目录：`zic_v0.31.0-dev.156_reader-progress-mihon-chapter-artwork-identity`。
- 共 1064 个发行文件；未包含 `.git`、`.zic-workspace.json`、`.dart_tool`、`.deps`、`build`、`.gradle`、`target`、`__pycache__`、`*.pyc`、`*.class`、`*.rej`、`*.orig`。
- `unzip -t` 通过。
- 从独立解压副本重新执行版本、documentation、Dart structure、directive order、Pipeline compile boundary、dev.155/dev.156、test quarantine、Android runtime、Mihon、Venera、source-resource、Reader/Pipeline/UI、network browser 与 native header合同，均通过。
- 组合执行达到单次执行窗口时仅从尚未完成的项目继续验证；超时本身未被计为通过。

## 环境限制

当前环境未发现 Flutter/Dart SDK、完整 Android SDK/NDK、Cargo/rustc 与 ADB，因此不声明 `flutter analyze`、Dart/Flutter owner tests、APK 构建或真机 Reader 性能、章节目录与封面生命周期已经通过。唯一基线缺少锁定 `third_party/source_archives/libwebp-1.6.0.zip`，因此 dev.98 与对应 libwebp source build/smoke 未执行。
