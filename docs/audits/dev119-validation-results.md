# dev.119 验证结果

## 已通过

- repository structure、documentation responsibility、Dart structure、library directive order、Pipeline runtime compile boundary；
- dev.75–dev.119 所有权门禁按组执行；因组合执行窗口中断的项目均从未执行项单独续跑；
- quarantine、frame pipeline Trace analyzer、vertical geometry/Trace；
- Android texture Kotlin stub、Android runtime dependency 与 Trace 合同；
- Mihon entry、Context、ABI、classloader、read-only staging、chapter；
- Venera network、native binary、headers、Reader preflight、bootstrap；
- Reader、Pipeline、UI、source binding、settings/login；
- Python compile、shell syntax、native header；
- 在全新 `/mnt/data/zic_dev119_deps` 中从锁定 `libwebp-1.6.0.zip` 构建 shared host 库，并通过 incremental、partial-blend、finite-loop smoke。

## 专项覆盖

- refill policy 跳过无新 source revision 的 waitingSource 页面；
- source wake 在全局 refill 重定向后保持 pending；
- 权威静态 output 在 demand gap 中保持同一 output；
- dormant output 在预算内不回收，超过预算后由 `frame-budget` 回收；
- `PageRole.visible` 已从角色、策略与 FrameBudget 中删除；
- analyzer 统计 `staticFrameKept`。

## 未执行

当前环境没有 Flutter/Dart SDK、Android SDK/NDK/Gradle、Cargo/rustc 和 ADB。因此没有运行 `flutter analyze`、Dart/Flutter owner tests、Android APK 构建、Rust tests 或真机验证。

## 说明

完整 `tool/check.sh` 未作为一次不可分割命令记为通过；较长检查按原顺序分组执行。超时本身未记为成功或失败。
