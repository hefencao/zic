# 2026-09-23 Reader 设置与 Android 系统栏审计

## 范围
本轮重新评估每漫画 adaptive/手动设置关系，整理全局 Reader 设置，新增全局分页方向、独立长按倍率和状态栏偏好，并修复 Android 16 上的系统栏控制。未修改 Pipeline、下载、缓存、source transport 或媒体调度。

## 根因
- “使用自适应设置”在模型上已独立，但清除手动设置仍会把 adaptive switch/profile 一起清掉，ownership 不一致。
- 全局阅读设置按历史追加顺序排列，双击与长按参数交错，详情页预览密度也误放在 Reader 设置。
- 长按倍率隐式取双击倍率，导致两个不同手势没有独立参数。
- `ReaderRouteTransitionGate` 首次 commit 后 `applyNow()` 永久 no-op，控制栏变化/App resume 无法再次同步 system UI。
- 当前 Flutter targetSdk 36；Android 16 对旧非 edge-to-edge `SystemUiMode` 不再提供可靠 show/hide 语义，必须由 Android WindowInsets API 落地。

## 实现边界
- `AppPreferencesController` 继续唯一持久化全局 Reader 偏好。
- `ReaderSessionSettings` 只读投影 paged direction、long-press scale、status-bar visibility。
- `ReaderView` 只消费 gesture 参数，不持久化。
- `reader_runtime` 负责 Reader system-bar presentation；Android plugin 使用 `WindowInsetsController`。
- 每漫画 adaptive policy 与 manual override 两条轴保持独立；清除 manual override 不清 adaptive。
- 全局方向是 fallback，不覆盖漫画显式方向或高置信 adaptive 方向。

## 真机验证
设备：Android 16 / API 36；已安装 ZIC targetSdk 36。使用 `adb install -r` 保留现有数据。

1. 阅读设置页：
   - “布局”中可见分页/连续、LTR/RTL/跟随来源，自有数据缺少新 key 时显示默认 LTR；
   - “界面”中“显示系统状态栏”默认开启；
   - 双击设置与“操作 · 长按放大”分区分离；
   - 长按倍率显示默认 2.00x。
2. 每漫画设置：
   - “使用自适应设置”与“启用本漫画覆盖”分区显示；
   - 真机对“要成為男子漢”开启手动覆盖后，自适应开关仍保持可见并为开启；
   - 当前 adaptive 结果显示条漫/纵向 61%（页面比例）。
3. status bar 开启：
   - 进入 Reader 后 `dumpsys window` 的两个 statusBars source 均为 `visible=true`；
   - Reader 控制默认隐藏时 navigationBars 为 `visible=false`。
4. status bar 关闭：
   - 进入 Reader 后两个 statusBars source 均为 `visible=false`；
   - 呼出 Reader 控制后 statusBars 仍为 false，而 navigationBars 变为 true，证明两个轴独立。
5. Reader exit：
   - 返回详情页后 statusBars 与 navigationBars 均恢复 `visible=true`；Android 的正常 insets 动画期间可短暂保持旧 visible 状态，settled 后两栏均可见。
   - 原生 owner 只快照并恢复进入 Reader 前的 behavior/appearance/颜色，不快照 route 过渡帧中的可见性；后者曾在复核中证明会把临时 hidden 状态错误当成退出目标。
6. 测试结束后已把设备上的“显示系统状态栏”偏好恢复为开启，没有保存临时的漫画手动覆盖。

## Toolchain
- focused Reader settings/gate/system-ui tests：PASS。
- Reader zoom tests：22/22 PASS。
- App reader-controls + misc-settings tests：52/52 PASS。
- `python3 tool/test_reader_layout_settings_contract.py`：PASS。
- arm64 Android debug APK：PASS，包含 Kotlin WindowInsetsController 实现。
- scoped analyzer 无 error/warning；仍存在仓库既有 info-level lint debt。
- 最终 `tool/check.sh`：PASS，exit 0；历史 dev.75–dev.338 ownership/contract gate、全仓 package/App tests、
  Android armeabi-v7a/arm64-v8a/x86_64 三 ABI debug APK build 与 Rust `media_core` 22/22 均通过。
  部分 Kotlin/Java helper 在当前 WSL 工具链按既有门禁规则显示 SKIP；不影响最终 gate 成功。
