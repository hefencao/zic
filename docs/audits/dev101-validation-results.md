# dev.101 Validation Results

## Baseline

- 输入基线：`zic_v0.31.0-dev.100_test-quarantine-texture-schedule.zip`
- 当前版本：`0.31.0-dev.101`
- 设备证据：`zic-debug-trace-2026-08-03T08-43-07.jsonl`

## 已执行

### 仓库与文档

- `tool/check_repo.py`：通过。
- `tool/check_documentation.py`：通过。
- `tool/check_dart_structure.py`：通过，323 个 Dart 文件、121 个测试文件。
- `tool/test_dart_library_directive_order.py`：通过。
- `tool/test_pipeline_runtime_compile_boundary.py`：通过。
- 修改过的 Python 工具执行 `python3 -m py_compile`：通过。
- 全仓搜索未发现当前代码继续引用已删除的 dev.100 聚合门禁、版本绑定 quarantine marker 或 App build `+100`。

### 所有权与历史回归门禁

- dev.75 至 dev.99 静态门禁：通过。
- quarantine allow-list 和 owner coverage：通过。
- Android texture schedule timing contract：通过。
- Kotlin texture bridge stub compile：通过；仅有 stub 未使用参数 warning。
- frame Pipeline Trace analyzer fixture：通过。
- vertical geometry、artwork cache 和 Trace contract：通过。

### Android、Mihon、Venera 与 UI 合同

以下分组执行通过：

- Android runtime dependency closure、mutation 和 Trace export；
- Venera network policy、native binary、response headers、Reader preflight 和 bootstrap；
- Mihon entry、payload Context、ABI routing、classloader、read-only staging 和 chapter contract；
- source resource binding；
- Reader layout settings；
- Pipeline demand stability；
- Reader streaming；
- UI architecture；
- external login/settings；
- native header。

较长分组两次达到单次命令执行窗口后中断；从未执行项继续运行均通过。超时未记为通过或失败。

### 锁定 libwebp

在全新 `/mnt/data/zic_dev101_deps` 中执行：

```bash
ZIC_DEPS_DIR=/mnt/data/zic_dev101_deps ./tool/check_webp.sh
```

结果：

- 项目内锁定 `libwebp-1.6.0.zip` 校验通过；
- 零 fuzz prepared patch 通过；
- host shared build 通过；
- incremental 与 loop Animated WebP fixture 通过。

### Trace analyzer

执行：

```bash
python3 tool/analyze_frame_pipeline_trace.py \
  /mnt/data/zic-debug-trace-2026-08-03T08-43-07.jsonl
```

旧 Trace 中 91 条 `platformSchedule` 被规范化为 `platformScheduleLegacy`，因为该版本的字段混合了 platform-thread queue 和实际 API call。dev.101 新字段尚无设备样本，不能据旧 Trace判断哪一部分占主导。

其他单设备数值和逐帧列表保留在 `dev101-documentation-trace-audit.md`，不进入 Architecture、Spec 或 README。

## 未执行

当前环境未找到：

- Flutter SDK / Dart SDK；
- Cargo / rustc；
- Gradle 与完整 Android SDK/NDK；
- ADB 设备。

因此未执行：

- `flutter analyze`；
- Dart/Flutter tests；
- Rust tests；
- Android debug/release；
- dev.101 真机 schedule queue/call 复验。

## 结论

- 文档职责、引用闭包、静态所有权、Kotlin stub 和 host-native libwebp 构建已验证。
- Android timing 拆分仅为 Implemented/Verified-static；设备效果仍为 Unverified。
- 前帧卡顿和三项 Source Browser quarantine 均未关闭。

## 独立打包副本复验

将工作树复制为独立目录 `zic_v0.31.0-dev.101_documentation-boundary-schedule-timing`，清除生成物后重新执行：

- repository、documentation、Dart structure、directive order；
- Pipeline compile boundary；
- quarantine 和 texture timing contract；
- Kotlin texture stub compile；
- Trace analyzer fixture；
- Android Trace、Pipeline demand、Reader streaming、UI architecture 和 native header；
- 使用另一份全新外部依赖目录执行锁定 libwebp shared build 和两种 Animated WebP smoke。

上述均通过。独立副本未使用工作树 `.deps` 或编译产物。
