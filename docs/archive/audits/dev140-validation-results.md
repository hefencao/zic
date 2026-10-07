# dev.140 验证结果

## 已执行并通过

- documentation、Dart structure、directive order 与 Pipeline compile-boundary 静态检查。
- `tool/check.sh` 实际列出的 dev.75–dev.140 历史门禁；其中 dev.98 因基线缺少锁定归档而未执行。
- 漫画源分类/显式分页、Mihon 语言模型、等面积预览专项门禁。
- Android runtime/Trace、Mihon、Venera、Reader、Pipeline、UI、登录和设置合同。
- Kotlin texture bridge stub 编译。
- native header 检查。
- clean `zic-main.zip` 基线中的 patch check/apply、逐文件内容与执行位比较。
- 正式 ZIP 独立解压后的核心复验。

## 基线既有阻塞

- `third_party/source_archives/libwebp-1.6.0.zip` 在用户上传的 `zic-main.zip` 中不存在，因此 `check_repo.py`、dev.98 和锁定 libwebp source build/smoke 无法执行。本轮没有从旧版本补入该文件。
- `tool/test_source_resource_binding.py` 在未修改的 `zic-main.zip` 基线中也会失败：门禁仍要求旧文本 `_transports.loaderFor(source, uri)`，当前生产实现已不包含该调用。本轮未恢复旧 facade。

## 未验证

当前环境没有 Flutter/Dart SDK、完整 Android SDK/NDK、Cargo/rustc 和 ADB，因此未执行 `flutter analyze`、Dart/Flutter owner tests、APK 构建和目标设备 UI 验证。
