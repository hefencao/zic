# dev.77 Pipeline 媒体运行时原子迁移审计

基线：`zic_v0.31.0-dev.76_reader-page-loading-ownership`。

Mihon 与 VibeVenera 参考仓库保持只读；本轮只偿还 ZIC 自身 Reader encoded-source/decode/upload/output 边界债务。

## 一、问题清单

### 编译错误风险

- `PipelineReaderSessionFactory` 当前只原子绑定 `SourceFactory`，没有同时绑定 `CursorFactory`、`FrameUploader`、输出投影和关闭生命周期；直接新增独立参数会形成半更新配置。
- `LiveCoordinator` 当前未接入生产 `DecodeRegistry`/`UploadRegistry`，因此策略虽生成 decode/upload demand，真实 cursor/upload 仍由 `local_media_ui.NativeWebpPlayer` 另行执行。
- 删除 `PipelinePageStream.source` 会同时影响 `LocalImagePlayer`、`NativeWebpPlayer`、Reader runtime 导出和相关测试，必须一次迁移所有调用方。
- 新 composition package 必须加入 workspace、共享 analyzer/test runner 和静态仓库门禁，不能只在 App 间接编译。

### 产品错误

- Reader WebP 同时存在 Pipeline decode/upload demand 与 Presentation 自建 native cursor/texture 生命周期；前者只调度、后者真正执行，形成名义所有权与实际所有权分裂。
- `PipelinePageStream.source` 暴露 mutable `EncodedSource`，Presentation 可读取 epoch/kind 并直接创建 cursor，违反只读输出投影边界。
- `NativeWebpPlayer` 直接创建/释放 `NativeSource`、`NativeCursor`、`AndroidTextureLease`，Reader 页面退出和 target 重建时由 Widget 生命周期决定底层资源关闭，而不是 Pipeline demand/session 生命周期。
- Reader 播放暂停/倍速当前直接作用于 Presentation 播放器；正确路径应是用户命令进入 `PipelineReaderSession`，由 Pipeline-owned output/playback 生命周期执行。

### 性能问题

- 当前 trace 中相同当前页可在 Pipeline demand 和 Presentation native start 两处记录 decode 语义，无法可靠区分真实 lane 工作与 Widget 自建工作。
- Presentation target 重建会直接销毁 cursor/texture；迁移后应由稳定 `DecodeId`、decode/upload registry 和 output claim 合并，避免同 identity 双链。
- Android texture 必须按 DecodeId 复用 session-local lease；不得每帧创建 texture，也不得由页面 Widget 缓存平台 handle。
- 非 WebP 页面不得因为启用生产 DecodeRegistry 而反复进入 native unsupported 失败；其完整 artifact 仍走既有 Flutter/static presentation 路径，WebP 才进入 native cursor。

### 测试错误/缺口

- 现有 Pipeline runtime 测试只验证 download/streaming projection，未验证生产 decode/upload registry 真正接线。
- 现有 local-media streaming 测试依赖 `PipelinePageStream.source`，应改为注入只读 `PipelinePageOutputStream` fixture。
- 需要静态门禁禁止 `local_media_ui` 再出现 `EncodedSource`、`NativeCursorFactory`、`AndroidTexturePresenter.create` 的 Reader streaming 路径。
- 需要验证输出 claim 在 replacement/detach/dispose 时按顺序 release，且外部注入的 runtime factory 不被错误关闭，session-owned runtime 必须关闭。

## 二、所有权清单

| 状态 / 资源 / 命令 / 生命周期 | dev.76 当前所有者 | dev.77 正确所有者 | 原子迁移处理 |
| --- | --- | --- | --- |
| SourceFactory/CursorFactory/Uploader/Output projector 组合 | SourceFactory 在 Pipeline；其余散落 Presentation | composition 注入一个 `PipelineMediaRuntimeFactory` 原子能力 | 新增原子 factory；每个 Reader session 创建一个 owned runtime |
| EncodedSource | DownloadSession ingress，但经 stream 泄漏 | downloads/sessions/Pipeline 内部 | 删除 `PipelinePageStream.source` 与 snapshot source |
| native cursor / decoded frame holder | `NativeWebpPlayer` 与未启用的 DecodeRegistry 两套语义 | `DecodeRegistry` / `DecodeSession` | Pipeline session 实例化并交给 LiveCoordinator |
| upload/output frame | `NativeWebpPlayer` 直接 texture present | `UploadRegistry` / `UploadSession` | Pipeline session 实例化生产 uploader |
| Android texture lease | 页面 Widget | session-owned platform media runtime | uploader 按 DecodeId 复用，runtime close 统一释放 |
| 可见 texture/image | Widget 直接拿 textureId/ui.Image | `PipelinePageOutputStream` 的 opaque `PipelinePageSurface` | Presentation 只调用 surface.build，不看到 handle |
| output present claim | 不存在 Pipeline 权威 claim | Pipeline output stream controller | replacement/detach/dispose 释放 claim |
| 动画 frame advance | `NativeWebpPlayer` Timer | Pipeline coordinator + UploadSession playback timer | Pipeline session ticker 驱动 due frame；暂停/倍速是 session 命令 |
| 页面 loading/invalid UI | local_media_ui | local_media_ui | 保持；只消费输出 snapshot，不拥有底层资源 |
| 非 WebP 完整文件 decode | local_media_ui Flutter Image/codec | 当前仍为 presentation-safe ImageProvider 路径 | 不混入 native WebP cursor；后续若统一需独立 ADR |
| Reader session close | PipelineReaderSessionHost | PipelineReaderSessionHost -> PipelineReaderSession | 先停 ticker/output，再 coordinator/registries，再 media runtime/source/workspace |

## 三、被否决方案清单

- **只删除 `PipelinePageStream.source`，然后让页面改回完整字节 native decode**：只是换入口，仍由 Presentation 拥有 cursor/upload；否决。
- **Pipeline 与 `NativeWebpPlayer` 同时 decode，页面择优显示**：双链会重复 CPU/GPU/流量与 telemetry；否决。
- **给 factory 增加多个独立 setter（source/cursor/uploader/projector）**：可能出现半更新能力组合；必须一个原子 runtime factory。
- **让 `pipeline_runtime` 直接依赖 `bridge` 或 `texture_bridge`**：核心反向依赖平台实现；否决。
- **把 textureId/native frame handle 作为公共 output snapshot 字段**：平台 handle 泄漏到 Presentation；否决。
- **每帧创建/释放 Android texture**：破坏上传性能与稳定 identity；否决。
- **为避免 native unsupported 而关闭 decode demand 或缩小 2/1 窗口**：违反既定策略；非 WebP 应在 DecodeSession 按内容能力结束，而不是退化 policy。
- **通过完整 JSON/Base64 或插件 RPC 传递正文**：与本迁移无关且违反插件传输边界；否决。

## 四、实际迁移结果

### 原子能力与依赖方向

- 新增 `pipeline_runtime.PipelineMediaRuntimeFactory`/`PipelineMediaRuntime`，将 source factory、cursor factory、frame uploader、output projector 与 renderer 作为一个不可拆分值注入。
- 新增 `pipeline_native`，集中实现 `NativeSourceFactory`、`NativeCursorFactory`、Android texture uploader、Flutter image fallback 与 opaque surface projector。
- `apps/app` 的 `defaultLocalMediaPipelineFactory` 是唯一默认平台选择点；`local_media_ui` 只要求传入 `PipelineReaderSessionFactory`，不默认创建平台 runtime。
- `pipeline_runtime` 未引入 `bridge`、`texture_bridge`、FFI pointer 或 Android handle。

### 状态、命令与 API

- `PipelinePageStream` 删除 mutable `EncodedSource` 字段/访问器，仅保留 identity、transfer/content snapshot 和受控 prefix 读取。
- 新增 `PipelinePageOutputStream`：内部 claim/present/project，外部只读 snapshot。Presentation 只能调用 `PipelinePageSurface.build`，不能取得 `DecodeId`、`OutputFrame`、`PresentClaim`、textureId 或 native frame handle。
- Reader playback controller 的 pause/speed 通过 `PipelineReaderSession.setPlayback` 原子写入 UploadRegistry；新旧 UploadSession 均继承同一配置，timer 在实际 present 完成后读取权威 speed，避免异步 present 覆盖较新的用户命令。
- 用户 pause 与 viewport freeze 是两个独立原因；transition 页可在首帧 timer 建立前记录冻结意图，解除用户 pause 不会错误唤醒仍被 viewport 冻结的页面。
- App 的 `MediaPipelineReaderScreen` 同步从 `NativeWebpPlayer(pageStream: ...)` 迁移到 `LocalImagePlayer(pageStream + pageOutput)`；删除旧调用而非恢复兼容参数。
- `LocalImagePlayer` 对 Pipeline streaming 增加原子断言：有 page stream 时必须同时有 page output。

### 生命周期与纹理

- Reader session 关闭顺序为：停止 ticker/解绑 observation、释放 page-output claims、排空 coordinator、完成 artifact handoff、关闭 upload/decode registry、关闭 media runtime、关闭 downloads/source/transports/workspace。
- Android uploader 以 `DecodeId` 为 key 复用 texture slot；动画换帧不释放 slot。
- trim/detach/reset/dispose 退休 identity。slot 从 active map 移除后仍由 output frame owner 保活；最后一个 claim 释放导致 frame dispose，继而释放 texture lease。
- output replacement/清空先发布新 snapshot，再在下一 Flutter frame 释放旧 claim，避免旧 `RawImage`/texture widget 尚未重建时底层 image/lease 已先销毁。
- `LocalImagePlayer` 只在 opaque surface 已进入 widget tree 的下一帧报告 first frame，而不是在 output snapshot 到达时提前宣告。
- viewport 播放门只接收 `DemandPlan.uploads` 的 current/transition identity，不会为了冻结纯预解码页而提前创建 UploadSession；Reader playback ticker 只在当前 upload plan 中至少一个 `PlaybackTimer` 为 running 时存在，静态页与全部 viewport-frozen 页不会维持 60Hz 空轮询，present/resume 状态变化会重新触发检查。
- runtime 记录 active 与 retired lease futures，close 等待全部 release 完成；create/present 失败不会卡住 teardown。

## 五、删除与保留

### 删除/替代

- 删除 `PipelinePageStream.source`、snapshot 中 encoded source 和所有 Reader Presentation 读取该 source 的路径。
- 删除 `NativeWebpPlayer` 的 Reader streaming 参数、source attach、增量等待和页面 cursor/texture 生命周期。
- 替代 App 演示与 smoke test 中对已删除 Reader streaming 参数的调用；没有新增兼容 facade。

### 有意保留

- `NativeWebpPlayer` 仍用于独立 WebP codec/演示诊断的完整字节路径，不再接收 Pipeline source，也不是 Reader WebP production 路径。后续若删除该诊断，应独立迁移对应产品入口和测试，不能重新接入 Reader。
- 非 WebP 静态图/GIF 的完整 artifact Flutter Presentation decode 未纳入本轮 WebP streaming 原子迁移；该剩余边界已写入 ADR 0061，不能误报为完成。
- +7/-3 下载、+2/-1 解码、current/transition upload、5/3/2 lane、GET/HEAD、插件 request-plan 与资源缓存行为未改。

## 六、验证记录

已在当前环境执行并通过：

- Dart 文件结构与 library directive 顺序检查。
- Pipeline runtime compile boundary、Reader streaming/output contract、UI architecture contract。
- dev.75、dev.76 与新增 dev.77 ownership gate。
- 仓库 workspace/依赖静态检查和全仓旧 API 引用搜索。
- Mihon/Venera/Android 的现有静态契约（最终打包前再次执行）。
- 使用用户上传的 `libwebp-1.6.0.zip` 本地源码构建 host library，并通过增量 decode 与 loop fixtures。

当前环境没有 Flutter/Dart SDK、Android Gradle wrapper 或 Cargo，因此 `flutter analyze`、Dart/Flutter tests、Android debug/release/kernel snapshot 与 Rust tests 只能记录为未执行，不能由静态门禁代替。

## 七、后续真机验证重点

1. current/transition 两个 upload output 是否只来自 Pipeline lane，trace 中不再出现 Widget 自建 decode 链。
2. target/DPR 变化时旧 surface 保持到新 surface ready，且无重新“连接中”或空白闪烁。
3. 动画 pause/resume/0.25–4x speed 的 timer rescale 与 loop rewind。
4. 长章节滑动后 texture/GPU memory 随 DecodeId 退休回落，而不是累计到章节关闭。
5. create/present 进行中立即退出时，output claim、retired texture 和 runtime close 均完成，无 late callback/use-after-release。
