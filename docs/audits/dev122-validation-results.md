# dev.122 验证结果

## 已通过

### 工作树静态与所有权合同

- repository structure、documentation responsibilities、Dart structure、library directive order、Pipeline runtime compile boundary；
- `tool/test_dev75_*.py` 至 `tool/test_dev122_*.py` 的全部现存历史门禁；dev.98 单独完成锁定 libwebp archive 与精确 patch prepare；
- test quarantine、Pipeline demand stability、Reader streaming/layout、UI architecture、texture timing、vertical geometry 与 Trace analyzer；
- Android texture Kotlin stub 编译、Android runtime dependency 与 Trace export contracts；
- Mihon entry、Context、ABI、classloader、read-only staging、chapter contracts；
- Venera network、native binary、response headers、Reader preflight、bootstrap contracts；
- source binding、external source settings/login、Python compile、shell syntax、native header。

### dev.122 新增证据

- 7/5/3/2 staged refill 顺序和 maxima，静态单帧满足语义保持；
- unsealed WebP 达到 30 个已证明可解帧后，在 `needMoreData` 边界重建同一 source epoch cursor 并投影 `partialPrefix=true`；
- active non-resumable transfer 离开窗口后继续完成，revisit promoted resource 不重新 open；
- 只取消 queued transfer；promoted、active、queued 或 retry-pending DownloadSession 去重；
- download recovery 跨 policy revision 保留有界 round，并在真实 source 字节增长后清除失败 streak；
- PageAsset ratio 稳定、ReaderView 局部 notifier 与 2 logical px anchor 阈值；
- Trace analyzer 增加 `partialPrefixLoopCount`、`partialPrefixLoops`、`downloadRecoveryCount` 与 `downloadRecoveries`。

### 锁定 libwebp 工具链

- 在全新外部依赖目录 `/mnt/data/zic_dev122_webp_deps` 中，从包内锁定 `libwebp-1.6.0.zip` 完成 exact patch preparation；
- shared host CMake/Ninja build 通过；
- incremental、partial-blend 与 finite-loop Animated WebP smoke 通过。

## 执行窗口说明

- dev.75–dev.97 的组合执行在 dev.98 开始时达到 120 秒窗口；dev.98 随后单独执行并通过。
- 平台组合检查分别在 Kotlin texture、Mihon ABI、Mihon chapter 和 external login 开始时达到执行窗口；这些项目均从未执行项单独续跑并通过。
- 未把任何超时或中断本身记录为通过。

## 未执行

当前环境没有 Dart/Flutter SDK、完整 Android SDK/NDK/Gradle、Cargo/rustc 和 ADB。因此无法声明：

- `flutter analyze` 或 Dart/Flutter owner tests 已实际运行；
- Android debug/release APK 已构建；
- Rust tests 已运行；
- 7/5/3/2、30 帧 prefix 循环、活动传输保留、跨 revision 退避和纵向滚动改善已完成真机验证。
