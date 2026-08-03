# dev.100 验证记录

- 输出版本：`0.31.0-dev.100`；App：`0.31.0+100`。
- 唯一代码基线：`zic_v0.31.0-dev.99_frame-pipeline-timing.zip`。
- 中文提交标题：`治理过时测试并修复 Android 纹理调度回复阻塞`。

## 已执行并通过

### 仓库与所有权门禁

- `python3 tool/check_repo.py`
- `python3 tool/check_dart_structure.py`：323 个 Dart 文件、121 个测试文件。
- `python3 tool/check_directive_order.py`
- Pipeline 编译边界门禁。
- dev.75 至 dev.100 静态所有权与回归门禁。
- Android runtime dependency、Trace、native header 合同。
- Mihon entry、Context、ABI、classloader、只读 staging、chapter 合同。
- Venera network、native、headers、preflight、bootstrap 合同。
- source binding、Reader settings、Pipeline demand、Reader streaming、UI architecture、external login/settings 合同。

完整 `tool/check.sh` 曾因单次命令执行窗口超时中断；未执行项随后按组继续运行，未发现失败。超时未记为测试通过或失败。

### 测试治理

- `python3 tool/check_test_quarantine.py`
- `python3 tool/test_dev100_test_quarantine_texture_dispatch.py`
- 默认测试中所有 `skip` 必须带 `ZIC-QUARANTINE(dev.100)` 标记并登记于 `docs/testing/TEST_QUARANTINE.md`。
- 当前仅允许三项 Whole-App source 时序测试处于 quarantine；每项均登记原因、仍运行的所有者级覆盖与解除条件。
- 删除 App 层重复的 adaptive Reader classifier 测试；所有者级覆盖保留在 `reader_runtime`。

### Trace 与 Android texture

- `python3 tool/test_frame_pipeline_trace_analyzer.py`
- `python3 tool/test_texture_bridge_kotlin_compile.py`
- Kotlin stub 编译验证 `TextureBridgePlugin.kt`：通过，仅有测试 stub 的未使用参数警告。
- 对用户上传的 dev.99 Trace 共分析 302 条精确 `framePipelineTiming`：旧版记录的 `decodedToUpload` 多数为 successor 提前解码产生的正常 lead。归一化后主导节点为 `platformResultDispatch` 152 条、`nativeDecode` 107 条、真实 `uploadBackpressure` 25 条、`channelDispatch` 11 条、`sourceWait` 3 条、`decodeDispatch` 3 条、`outputPrepare` 1 条。
- dev.100 将 `decodedLeadMicros` 与 `uploadBackpressureMicros` 分开，并修正重叠平台阶段的主导节点计算。

### 锁定 libwebp

使用项目内锁定的 `third_party/source_archives/libwebp-1.6.0.zip`，在全新的外部依赖目录执行：

```bash
ZIC_DEPS_DIR=/mnt/data/zic_dev100_deps bash tool/check_webp.sh
```

结果：

- 归档和真实源码哈希校验：通过。
- 零 fuzz VP8 TLS 补丁准备：通过。
- shared host CMake/Ninja 构建：通过。
- incremental Animated WebP smoke：通过。
- loop Animated WebP smoke：通过。

### 其他静态检查

- `tool/` 与 `native/` 下 shell 脚本语法检查：通过。
- 59 个 Python 工具脚本 AST 解析：通过。

## 错误报告 51 的处理状态

- 修复 `library_ui_test.dart` 与 `misc_settings_test.dart` 的直接编译漏项。
- 删除 RasterPlan 已过时的 renderer-upscale 状态 API 及其错误断言；保留 intrinsic decode 与 nearest-neighbour 所有者级合同。
- 修正 Reader 下载按钮测试，使其跟随 capability 注入，而不是静态/动画类型。
- 删除 App 层重复 classifier 测试。
- 删除把 Flutter filter quality 误当成 codec 放大行为的断言。
- 更新 pull-refresh 元数据合同：允许保存章节元数据，但继续断言未下载章节正文。
- 三项依赖 Whole-App 异步启动顺序、无法稳定证明目标的 source 测试已明确 quarantine，而非匿名跳过。

## 工具链限制与未验证项

当前执行环境未发现 Flutter/Dart、Cargo/rustc、Gradle、Android SDK/NDK 或 ADB。因此：

- 未运行 `flutter analyze`。
- 未运行错误报告 51 中的 Dart/Flutter 测试。
- 未执行 Rust build/test。
- 未执行 Android debug/release 构建。
- 未执行真机前帧播放与纹理可见性验证。

这些项目均不得描述为已通过；本轮完成的是源码修复、测试归属治理、静态闭包、Kotlin stub 编译和 host libwebp 实际构建验证。

## 最终 ZIP 复验

候选完整包已从独立目录重新解压并通过：

- `unzip -t` 完整性检查。
- `.git`、`.dart_tool`、`build`、`.gradle`、`.deps`、`target`、`__pycache__`、`.pyc`、`.class`、`.rej`、`.orig` 禁入扫描。
- repository、Dart structure、directive order。
- quarantine allow-list、dev.100 ownership、Trace analyzer fixture。
- `TextureBridgePlugin.kt` Kotlin stub 编译。
- 使用解压包内锁定 `libwebp-1.6.0.zip` 和全新外部 `ZIC_DEPS_DIR` 的 shared host 构建、incremental/loop Animated WebP smoke。

验证记录写回后重新生成最终 ZIP，并再次执行同等独立复验。
