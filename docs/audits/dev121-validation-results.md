# dev.121 验证结果

## 已通过

- repository structure、documentation responsibilities、Dart structure、library directive order、Pipeline runtime compile boundary；
- dev.75–dev.121 历史所有权门禁；
- test quarantine、demand stability、Reader streaming、texture timing、Trace analyzer、vertical geometry；
- Android texture Kotlin stub 与 Android runtime dependency/Trace contracts；
- Mihon entry、Context、ABI、classloader、read-only staging、chapter contracts；
- Venera network、native、headers、Reader preflight、bootstrap contracts；
- Reader、Pipeline、UI、source binding、external login/settings 静态合同；
- Python compile、shell syntax、native header；
- 锁定 `libwebp-1.6.0.zip` 的零 fuzz prepare、全新 shared host CMake/Ninja build；
- incremental、partial-blend、finite-loop Animated WebP smoke。

组合检查多次仅在下一项开始前达到单次执行窗口；未执行项均随后单独续跑并通过，没有把超时本身记为通过。

## 候选 ZIP 独立复验

从候选 ZIP 的独立解压目录重新验证并通过：

- 禁入生成物扫描；
- repository structure、documentation responsibilities、Dart structure、library directive order、Pipeline runtime compile boundary；
- dev.120、dev.121 所有权门禁；
- test quarantine、demand stability、Reader streaming、Reader layout、UI architecture、Trace analyzer、vertical geometry；
- Android texture Kotlin stub 编译；
- 从候选 ZIP 内锁定归档重新 prepare 并构建 `libwebp-1.6.0` shared host 库；
- incremental、partial-blend、finite-loop Animated WebP smoke。

独立 `libwebp` 首次构建在当前单次执行窗口内被终止；从同一解压目录和依赖目录续跑后完整通过。没有把中断本身记为通过。

## 正式 ZIP 独立核心复验

正式 ZIP 生成后，从新的独立解压目录再次验证并通过：

- ZIP 完整性与禁入生成物扫描；
- repository structure、documentation responsibilities、Dart structure、library directive order、Pipeline runtime compile boundary；
- dev.121 专项合同与 test quarantine；
- Android texture Kotlin stub 编译。

正式包与已完成独立 libwebp build/smoke 的候选源码仅相差本验证记录，因此没有把文档更新描述成新的产品源码验证。

## 未执行

当前环境没有 Flutter/Dart SDK、Android SDK/NDK/Gradle、Cargo/rustc 和 ADB。因此无法运行 `flutter analyze`、Dart/Flutter owner tests、Android APK 构建、Rust tests 或真机滚动性能验证。新增 owner tests 已写入源码并通过静态闭包检查，但未在本环境实际执行。
