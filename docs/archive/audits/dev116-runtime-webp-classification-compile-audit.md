# dev.116 运行时 WebP 分类与编译闭包审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.115_empty-artifact-self-heal-static-host-keepalive.zip`。
- 设备 Trace：`zic-debug-trace-2026-08-04T04-32-32.jsonl`。
- 编译报告：`错误报告(55).txt`。

## 问题清单

### 编译

- `ArtifactCacheManager` 在 `ArtifactCacheBackend` 局部变量上调用只存在于可选接口的 `invalidateArtifact`，两处无法编译。dev.115 因而没有形成可运行设备包，不能用该次设备表现验证 dev.115 自愈。
- `pipeline_reader_session.dart` 出现重复 `artifactReadMicros` 局部声明；已删除并加入专项门禁。

### 产品

- Trace 的 Reader 3 为 28 页 Venera 纵向章节；初始 page 0–4 已挂载，current=2，但首个 plan 仅 `decodes=4/uploads=1`，`staticWarmDecodes=0/staticWarmUploads=0`。
- 这些 WebP 解码结果为单帧、`durationMicros=0` 并正常结束；来源 `animatedHint` 与权威结果不一致。邻页因此要等成为 current/transition 才得到 upload，表现为无限 loading。
- Trace 中纵向 host 的 `keepAlive=false`，说明旧实现用 `animatedHint` 阻止了静态 WebP host 保留。

### 架构

- cache invalidation 对所有生产 backend 都是自愈必需原语，不存在合理的“backend 不支持失效”状态；可选 capability 增加了类型与测试 fake 复杂度。
- 媒体是否动画只能由 decoder/cursor 权威确认，扩展名和来源元数据只能作为未分类前的 hint。

## 修改与所有权

| 修改 | 所有者 |
|---|---|
| backend 必需 `invalidateArtifact` | `downloads` |
| cursor 完成后上报 `AnimationInfo` | `sessions` |
| page 运行时分类与强制 replan | `pipeline` |
| classification Trace 与 output 同步 | `pipeline_runtime` |
| vertical current±4 轻量 host 保活 | `reader` |
| classification analyzer/fixtures | `telemetry/tool` |

## 推断边界

- 两页静态且零动画时，对未分类页的一帧 static-warm 是低风险章节级推断，不是永久媒体分类。
- 发现任一权威动画页后立即停用该推断。
- 权威分类只在完整 cursor end 后产生；partial `NeedMoreData` 或暂时 duration=0 不触发。

## 保持不变

- 下载 7/3、composition 全局 5 槽和来源 bucket。
- 动画 c/n/m/p 8/6/4/3 与 last keep。
- 静态 96 MiB 选择预算、128 MiB FrameBudget。
- durable direct ingress、texture pool、事件驱动 waitingSource、partial WebP prefix。

## 未验证

当前环境没有 Dart/Flutter、Android SDK/NDK/Gradle、Cargo/rustc 或 ADB。新增 Dart owner tests、analyzer、Android APK 和修复后设备行为均未执行。
