# Implementation Status

源码版本：0.31.0-dev.328
App build：0.31.0+328

本文件只描述当前源码快照和验证等级。历史见 CHANGELOG.md，单轮证据见 docs/audits/。
验证等级：Implemented、Verified-static、Verified-toolchain、Verified-device、Unverified。

## 1. 当前所有权与实现快照

### 调度与传输 (NetLane & Transport)
- 页面网络调度由共享 NetLane 唯一调度：保持 normal 5、current 高优先级保留槽 1。
- 历史阶段演进基线（已合入稳定架构）：dev.192, dev.195, dev.196, dev.197, dev.198, dev.199, dev.200, dev.203 bounded retention, dev.268, dev.269, dev.271。
- 传输并发状态：dev.271 globalRunning 统计受限，支持 active current-class demotion 与 40分 差值抢占。
- 任务排队在 Venera gate wait 期间保持实时优先级感知；响应停驻采用 dev.268 parked-response-eviction 机制。
- dev.269 区分 demanded=true 与闲置流；TaskControl 支持有界 paced drain 与单 invocation 串行保障。
- 外部源传输：VeneraHttpCacheStore 保持 6h 有效期与 targeted force-miss 规约。

### 存储与恢复 (Storage & Ingress)
- 本地准备：设立 physical-local-prepare 并限定 local-prepare operation 上限为 max2。
- 零拷贝读取：冷启动 cold partial 读取通过 SQLite 索引与文件直接裁决，不向 durable store 随意 materialize durable-store。
- 断点恢复：保持 SourceEpoch、generation 与 frameUploaded / decode/upload 代际一致，提供 recoverable canonical partial。
- 资源会话：支持 media-empty 状态恢复，提供 residentBodyBacked 权威正文与 range hydrate256KiB 预热。
- 元数据权威：由 physical source metadata 提供 generation-local metadataPrefix 保证。

### 外部插件运行时 (Mihon & Venera)
- Mihon 1.4/1.6 versioned ABI asset 已共享 canonical `UncaughtExceptionInterceptor`、`UserAgentInterceptor`、`CloudflareInterceptor`；
  两套 `NetworkHelper.client` 保留 default-client 类型合同，同时 Cloudflare 行为继续委托 `network_bridge` 唯一 owner。
- 真实肉漫屋扩展 APK 的 default-client guard 已核对：要求上述三类存在且 Brotli 不存在；对应 contract test 已进入 `tool/check.sh`。
- 同一扩展 bytecode 的 Injekt 请求已核对为 `Application` + `Json`；host 现按 Mihon `AppBindings` 注入
  `Json { ignoreUnknownKeys=true; explicitNulls=false }`，并把 `Json` 纳入 common-runtime 完整性预检。

### 渲染与几何 (Pipeline & Reader View)
- 页面几何：ValueListenable 提供 pageDimensions 驱动的 ratio live feed 投影。
- 纵向模式：vertical模式只有extent真实变化 才能触发 anchor/geometry rebuild；vertical模式 保持布局稳定。
- 视口与上传：vertical hidden-upload规则不变；明确区分 source-canvas 与 decoded raster 职责。
- 原生纹理呈现：以 presentationIdentity 标识 resident surface，接入 Android SurfaceProducer。
- 缓存与淘汰：promoted LRU=8 维护热尾淘汰，当前 current 拥有最高抢占权威。

## 2. 当前开放问题
- 静态竖排功耗偏高：HeuristicPolicy 静态全量并发上传与逐页异步尺寸重绘引发整树颠簸。
- 纵排初始化 cacheExtent 保持 6 屏与 15 页 KeepAlive 常驻未收敛。

## 3. 验证矩阵
| 检查项 | 状态 | 说明 |
|---|---|---|
| repository / documentation / Dart 静态门禁 | Verified-static | 门禁与目录结构核对通过 |
| 架构合同与生命周期 | Verified-static | Reader/Pipeline/Sessions 边界已验证 |
| 跨平台桥接与平台编译 | Verified-toolchain | Kotlin 与 Android 依赖通过 |
| 设备性能与真机回归 | Verified-device | 基础链路真机采样验证通过 |
| 未集成组件与缺省归档 | Unverified | 部分外部归档与端到端链路未覆盖 |
| 当前特性交付与状态 | Implemented | 核心功能均已落盘实现 |
