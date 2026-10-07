# dev.229 validation results

## 当前环境

- Dart SDK：不可用。
- Flutter SDK：不可用。
- Kotlin compiler：可用；dev.206 facade stub compile gate实际通过。
- 基线继续缺少`third_party/source_archives/libwebp-1.6.0.zip`，未从旧版本或独立包补入。

## 已执行

- `check_documentation.py`：通过。
- `check_dart_structure.py`：通过，352个Dart文件 / 131个test文件。
- `check_test_quarantine.py`、UI architecture、Reader streaming、Pipeline demand stability、Pipeline runtime compile boundary：通过。
- dev.205–dev.229相关ownership/version/partial gates共32条，以8 workers并行执行全部通过；包含dev.206 Kotlin facade stub实际编译。
- dev.229新gate确认：版本warmup/Reader入口不再调用cross-version partial copy；`PartialDownloadHandoff` exact-first、direct verified-equivalent fallback、最长prefix选择、跨版本validator清空均处于production路径。
- `bash tool/check.sh`：退出1，仅因pinned libwebp archive缺失；未发现新的源码门禁失败。

## 未验证

当前环境没有Dart/Flutter，因此以下不能宣称通过：

- dev.229新增Dart行为测试实际执行；
- `flutter analyze`；
- Flutter tests；
- Android APK build；
- 真机cold partial equivalent restore。

## 发行重放

最终冻结版从pristine dev.228重新生成后，三条路径再次独立验证：

- ordinary Patch：missing=0 / extra=0 / content=0 / executable-bit=0 / type=0；
- 完整ZIP独立解压：missing=0 / extra=0 / content=0 / executable-bit=0 / type=0 / banned=0；
- Exact Patch Replay v1：missing=0 / extra=0 / content=0 / executable-bit=0 / type=0。
