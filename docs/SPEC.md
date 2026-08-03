# zic Product and Engineering Specification

本文件是规范，不是实施报告。`MUST` 表示发布合同，`SHOULD` 表示默认要求，`MAY` 表示可选行为。实现和验证状态见 `IMPLEMENTATION_STATUS.md`。

## 1. 产品范围

zic MUST 支持：

- Android 上的本地和远程漫画阅读；
- LTR、RTL 和纵向连续阅读；
- 静态图片与 Animated WebP；
- 章节下载、partial、resume 和离线 artifact；
- 漫画源浏览、详情、章节目录和受控插件扩展；
- 本地 Debug Trace 导出。

当前项目不承诺 DRM 绕过、通用视频播放、社交功能或模型直接控制底层资源生命周期。

## 2. Reader 行为

### 2.1 当前页

- current MUST 具有最高 download、decode 和 upload 优先级。
- current 不得被 near/far 工作阻塞。
- 当前 output 未被 replacement 前 MUST 保持可见。
- 页面 loading MUST 绑定到具体媒体区域，Reader 不得用全局 overlay 隐藏已有页面。

### 2.2 翻页

- midpoint 默认为 50%。
- 超过 midpoint 后，新 stable page MUST 成为 current 并开始播放。
- 旧页在仍可见时 MUST 保持 transition output并暂停播放。
- 交接不得产生 targetless demand gap、黑屏或重新创建同一 identity。
- 反向拖动 MUST 使用同一 observation/demand 机制，不得另建命令路径。

### 2.3 连续模式

- 内容 MUST 等比呈现，不裁切漫画正文。
- 不得用负位移、页面重叠或多套比例公式掩盖接缝。
- 几何统一使用 `height / width`。
- 小图可由 renderer 放大显示；codec 不得因 8 px 对齐下限错误放大 intrinsic target。

### 2.4 控制

- Reader MUST 默认支持沉浸模式。
- 页码跳转、暂停、倍速、方向和布局命令只通过 Reader facade 提交。
- UI 控件存在性 MUST 由 capability 决定，不能由“静态/动画”猜测下载或播放能力。

## 3. Pipeline 合同

### 3.1 Observation

`ReaderObs` MUST 至少表达：

- stable page；
- fractional position；
- viewport/presentation size；
- 阅读方向；
- interaction/zoom 状态；
- 单调 revision。

### 3.2 Demand

默认 demand：

- download：前 7 / 后 3；
- page decode：前 2 / 后 1；
- upload：current/transition；
- lane：5 / 3 / 2。

Policy MUST 输出 demand，不得直接创建 transport、artifact、cursor 或 texture。

### 3.3 Identity

- 同一 request plan、DownloadSession、artifact 和 decode task MUST 按稳定 identity 合并。
- source epoch/revision 变化后，旧结果不得提交。
- 首页、详情和 Reader 不得分别创建正文请求。
- canonical comic alias 只用于同源比较，不得替代插件请求 locator。

## 4. 下载与 artifact

- GET/HEAD MUST 零 body。
- GET/HEAD 不得携带只适用于实体 body 的 headers。
- partial MUST 是连续前缀并可恢复。
- 同一 DownloadId 只能有一个 active writer。
- seal/promotion MUST 原子更新 metadata。
- cache clear 不得删除 active artifact。
- promoted local artifact SHOULD 以 1 MiB 分块进入 session；普通网络 transport 默认 256 KiB。
- 读取失败 MUST 保留可归因错误，不得表现为永久 loading。

## 5. Animated WebP

- 两个 Dart decode isolate MUST 在 App 运行期常驻。
- current MUST 保留一个高优先级 decode 槽。
- libwebp 帧内 MUST 使用单线程。
- 不得安装额外 persistent libwebp worker pool。
- current SHOULD 保留两个 successor；transition SHOULD 保留一个。
- transition→current 的 same-key 不可中断任务 MUST 完成后 follow，不能取消并丢弃有效帧。
- metadata 未完成且 source 增长时 demux MUST 可刷新。
- native target canvas MUST 生成预乘 RGBA。
- Android 和 Flutter fallback 不得再次重复预乘。
- finite animation 到 EOF MUST 保留最后一帧；静态零时长帧不得启动 playback timer。

## 6. Android texture

- texture lease、SurfaceProducer 和 retained frame 由 `texture_bridge` 拥有。
- 每帧不得重复设置 Surface 尺寸；仅创建或真实 resize 时配置。
- blit MUST 复制预乘 RGBA。
- `scheduleFrame()` 必须在 platform thread 执行。
- MethodChannel 成功返回不得早于本次 schedule 调用完成。
- schedule 的 platform-thread queue 和 API call MUST 分别计时。
- replacement 前旧 frame MUST 保持有效。
- release MUST 等待最后一个 frame owner 释放。

## 7. 插件与来源

- 插件 MUST 在隔离、信任和权限门禁内执行。
- 插件只能返回 catalog 数据、request plan 或显式 transform 结果。
- 普通图片正文 SHOULD 由宿主 transport 流式下载。
- 插件不得访问导航、Reader、demand、artifact、App state 或底层缓存。
- Cookie、token、脚本 payload 和 Base64 正文不得原样写入 Trace。
- 目录错误不得伪造成“正文”单章节；synthetic 兼容必须由能力缺失和正文预检共同证明。

## 8. 资源缓存

- 封面、详情、搜索响应由 `resource_cache` 统一拥有。
- cache key MUST 包含 namespace、稳定 identity 和必要 revision。
- in-flight 相同请求 MUST 合并。
- App/Reader 不得创建私有图片字节 LRU。
- 页面正文 artifact 不得进入 response-cache 平面。

## 9. Telemetry

### 9.1 必须记录

- demand attach/detach；
- session state transition；
- writer acquire/release；
- source read 摘要；
- decode/upload/present failure；
- output retirement；
- 前帧端到端 timing；
- retry 与验证恢复结果。

### 9.2 前帧 timing

每个 output 激活后，前若干不同帧 SHOULD 保留逐帧 timing；后续仅记录慢帧、deadline miss 和错误。

阶段至少包括：

- decode lane queue；
- source wait；
- cursor create；
- worker ready/slot queue；
- isolate/native decode；
- upload backpressure/lane queue；
- output prepare；
- platform queue；
- schedule queue/call；
- blit/retain/replace；
- MethodChannel dispatch；
- fallback decode。

intentional successor lead 不得作为瓶颈。overlapping total 不得与子阶段重复参与 dominant。

### 9.3 隐私与体积

- identity 超过限制时使用稳定 hash 与原长度；
- 高频投影 MAY 固定窗口合并；
- 错误和生命周期边缘 MUST 保留；
- Trace 导出 MUST 有界；
- Trace 不得作为业务状态权威来源。

## 10. 测试

- 实现单元测试必须位于拥有该实现的 package。
- App 测试不得导入低层 `src/`。
- App 不得重复测试低层 identity、classifier 或 scheduler 算法。
- 异步测试 MUST 使用可控 Future、状态对象或稳定 key。
- 禁止固定 pump 猜测完成。
- 禁止对 lazy child 直接 `.single`。
- 禁止用文本包含匹配作为唯一身份。
- quarantine MUST 有稳定 ID、原因、仍运行的所有者级覆盖和解除条件。
- 未登记 skip MUST 使 repository gate 失败。

## 11. 发布门槛

发布候选 MUST：

1. 通过 `flutter analyze`；
2. 通过受影响 Dart/Flutter package tests；
3. 通过 App 目标 tests；
4. 通过 Rust/native tests；
5. 完成 Android debug 和 release 或明确记录缺失；
6. 通过 Mihon/Venera/Android 契约；
7. 从干净 ZIP 独立解压复验；
8. 不包含 `.git`、`.dart_tool`、`build`、`.gradle`、`.deps`、`target`、`__pycache__`、`.pyc`、`.class`、`.rej` 或 `.orig`。

未执行的门槛 MUST 在 `IMPLEMENTATION_STATUS.md` 和对应 audit 中标记为未验证，不得在 README、Architecture 或 Spec 中宣称通过。
