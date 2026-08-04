# ADR 0100：运行时 WebP 分类与纵向 Host 保留

**状态：Provisional**

## 问题

dev.115 存在两个独立问题。首先，cache 自愈通过可选 `ArtifactCacheInvalidationBackend` 实现，但 Dart 对接口类型判断后的局部变量没有形成可调用的交叉类型，`invalidateArtifact` 两处无法编译，因此 dev.115 没有形成可运行设备包。其次，纵向 Venera 章节中的静态 WebP 在解码前被来源元数据标记为动画；策略因此不给相邻页建立 static-warm upload，轻量 host 的 keep-alive 也被 `animatedHint` 阻断。页面虽进入视口和 ListView cache 范围，仍要等成为 current 才得到首帧。

## 决策

1. `invalidateArtifact` 成为 `ArtifactCacheBackend` 的必需存储原语。中央 manager 直接调用；删除可选 invalidation capability 与运行时类型判断。backend 不决定失效策略，只执行 manager 指定的条目删除。
2. 纵向 Reader 在 current 前后 4 页保留轻量 host，不再依赖不可靠的扩展名或 `animatedHint`。decoded frame、texture、cache body 与 session 仍由 Pipeline/FrameBudget 管理。
3. DecodeSession 在 cursor 权威结束且动画信息完整时上报 `AnimationInfo`。Pipeline 以 page index 记录运行时静态/动画分类，并强制重新规划 demand。
4. 单页确认静态后，该页进入一帧 static-warm。若同一章节至少两页已权威确认静态且尚无任何动画页，未分类页可作为一帧预热候选；一旦发现动画页，章节级推断立即停止。
5. 推断只影响未分类页的首帧预热，不改变真正动画页的 c/n/m/p staged 水位。运行时权威分类始终覆盖来源 hint 与章节推断。
6. 新增 `mediaClassified` Trace，记录 page、frameCount、loopCount 与 animated，供设备验证 demand 重规划。

## 所有权

- cache tier、损坏判断和失效策略：`downloads/ArtifactCacheManager`。
- 条目删除原语：`downloads/ArtifactCacheBackend`。
- 权威媒体分类：`sessions/DecodeSession`。
- 分类到 demand 的投影：`pipeline` 与 `pipeline_runtime`。
- 轻量页面 host：`reader`；重资源所有权不变。

## 拒绝方案

- 只对编译错误增加局部 cast：继续保留所有生产 backend 都必须实现的伪可选 capability。
- 将所有 `.webp` 视为静态：会破坏真实动画页水位和播放。
- 为所有 WebP 邻页直接建立动画 upload：放大解码、texture 和内存压力。
- 等页面成为 current 后再分类：无法解决纵向可见邻页无限 loading。
- 让 Widget 持有图片或 texture：会形成第二套缓存与生命周期。

## 解除 Provisional 条件

Flutter analyzer/tests 与 Android 构建通过；设备 Trace 出现权威 `mediaClassified`，静态 WebP 邻页在成为 current 前得到 static-warm 首帧；纵向 current±4 host 保持 mounted；真实动画 WebP 仍使用原 staged 水位。
