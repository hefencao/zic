# ADR 0320：Reader 设置轴与 Android 系统栏 ownership

## 状态
Accepted

## 问题
Reader 的设置长期按控件出现顺序堆叠，双击缩放、长按放大、布局、详情页预览和“沉浸”语义混在同一列表。与此同时，“默认沉浸阅读”把 Reader 控制栏、status bar 和 navigation bar 绑成一个概念，无法表达“隐藏阅读控制但保留状态栏”。

状态栏还有一个独立运行时缺陷：`ReaderRouteTransitionGate` 首次应用后永久将 `applyNow()` 变成 no-op，因此控制栏切换和 App resume 不会重新投影 system UI。进一步真机审计确认 ZIC 当前 targetSdk=36、测试设备 Android 16/API 36；Flutter 明确不再保证旧 `SystemUiMode.manual/immersiveSticky` 在该组合下有效，因此不能继续把它当 Android 系统栏 authority。

每漫画设置还存在概念泄漏：“使用自适应设置”与手动 override 虽已在模型上独立，但“清除本漫画设置”仍会顺带清 adaptive policy/profile，使 UI 名称与 ownership 不一致。

## 决策
1. 全局 Reader 设置按语义分区：
   - 布局：默认阅读模式、分页方向、自适应阅读、纵向拼接；
   - 界面：进入时隐藏阅读控制、系统状态栏三态（显示/隐藏/跟随控制栏）；
   - 操作·双击放大：双击一级/二级倍率 slider 与锚点；
   - 操作·长按放大：启用、独立倍率、释放、移动方式、拖动比率与边界；
   - 缩放质量：放大时解码分辨率。
   详情页预览密度移到外观，不再放在 Reader 操作设置。
2. 新增全局分页方向 `LTR / RTL / 跟随来源`，默认 LTR。方向解析为：漫画显式方向 > 高置信 adaptive 方向 > 全局分页方向。
3. 长按倍率成为独立全局值，默认 2.0x；不得借用双击一级/二级倍率。paged 与 continuous 共用该倍率投影。
4. 每漫画“使用自适应设置”始终独立于“启用本漫画覆盖”。手动 master 只展开/启用手动 override；“清除本漫画覆盖”不得改变 `comicAdaptiveEnabled` 或 adaptive profile。
5. `ReaderRouteTransitionGate` 只延迟首次 side effect；首次 commit 后 `applyNow()` 必须真正再次调用 side effect，以支持控制栏切换、设置变化和 App resume。
6. `reader_runtime` 是 Reader system-bar presentation owner。全局偏好为 `show / hide / followControls`；follow 只读取同一个 Reader controls visibility fact 后投影 `showStatusBar`，不让 Home/Pipeline 管理系统栏，也不增加第二个可见性 owner。
7. Android 由 reader_runtime plugin 使用 `WindowInsetsController`：
   - `statusBars()` 按三态策略解析后的结果 show/hide；
   - `navigationBars()` 跟随 Reader 控制栏显隐；
   - 使用 transient-bars-by-swipe behavior；
   - Reader exit/detach 必须主动显示 status/navigation bars，并恢复进入 Reader 前的 system-bar
     behavior、appearance 与颜色。可见性本身不得从 route 过渡帧采样后“精确恢复”，因为过渡帧可能已经暂时隐藏 system bars。
   旧 Flutter `SystemUiMode` 仅作为非 Android/缺插件 fallback。
8. 可见状态栏使用浅色图标以适配 Reader 黑色背景，避免“状态栏其实存在但图标不可见”的假隐藏。

## 后果
- “沉浸”不再是一个含混的三合一开关；控制栏、status bar 和 navigation bar 有明确关系；需要联动时由显式 `跟随控制栏` 表达。
- Android 16/targetSdk 36 不依赖被系统忽略的旧 Flutter system-UI mode。
- adaptive 与手动 override 的清除/开关语义一致，后续不会因为 UI 整理重新耦合。
- 双击与长按各自拥有完整设置组，后续新增手势参数无需再次交错插入。
- 这些变化只属于 App preferences / Reader presentation，不改变 Pipeline、NetLane、下载、缓存、source transport 或媒体生命周期 ownership。
