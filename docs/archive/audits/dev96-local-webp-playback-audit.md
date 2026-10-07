# dev.96 本地 WebP 播放所有权审计

## 问题清单

### 编译错误

- 当前基线未附新的 analyzer/编译日志；本轮先保持公共 API 迁移闭包，并以全仓静态引用检查补充无 Flutter SDK 环境下的验证。
- `NativePipelineMediaRuntimeFactory` 当前为 `const`；若构造时预热常驻 worker，所有生产与测试中的 `const` 调用必须一次迁移。

### 产品错误

- 小于 8 px 的源或目标会被 8 px 对齐下限错误放大，违背“不放大”和 contain 几何合同。
- transition 升级为 current 时，同 identity 的不可中断 native decode/upload 会被替换取消；已完成的有效帧随后被丢弃，纹理反复退休。
- Flutter fallback 对 native 已预乘 RGBA 再次预乘，半透明像素变暗。
- Android native blit 每帧重复设置 buffer geometry，并再次执行 alpha 预乘；Surface 尺寸和像素格式责任重复。
- 流式 WebP metadata 尚未完成时，demux 可能因已有 next descriptor 而不刷新，动画识别与后继帧调度滞后。

### 性能问题

- 两个 Dart decode isolate 在首次解码时才创建，并在最后一个 cursor 释放后销毁；页面重进反复支付 isolate 与 FFI 初始化成本。
- 单 FIFO 无 current 专用能力；邻页可占满两个 worker，current 不能及时进入解码。
- libwebp 帧内线程与两个 Dart isolate 并发叠加，切页时重型线程数量翻倍。
- libwebp VP8 大工作缓冲在连续帧解码间重复分配/释放。
- 本地文件/DocumentFile 读取仍为 256 KiB，未采用目标 1 MiB 顺序分块。
- current 动图水位仅保留一个后继帧，容易在 UI 抖动或一次慢帧后耗尽。

### 测试错误/缺口

- dev.94 静态合同仍把“最后 cursor 释放后关闭 worker”和 `use_threads = 1` 当成正确行为，已与本轮目标冲突。
- 缺少 transition→current 不取消同 identity decode/upload 的回归。
- 缺少小于 8 px 目标不放大的 Dart/Rust 回归。
- 缺少 Android 不重复配置 Surface、不重复预乘，以及 Flutter fallback 不重复预乘的门禁。
- 缺少 libwebp 1.6.0 补丁自动应用与禁止额外 persistent worker interface 的门禁。

## 所有权清单

| 状态/资源/命令/生命周期 | 当前所有者 | 正确所有者 | 本轮处理 |
|---|---|---|---|
| 两个 Dart decode isolate 与任务队列 | `bridge::_NativeDecodeWorkerPool`，但生命周期随 cursor owner | `bridge` 进程级 decode pool | 提前预热、进程期常驻、current/非 current 双队列 |
| 页面角色与 decode 优先级 | `sessions` 的 `DecodeDemand.role`，未传入 cursor | `sessions` 决策，`bridge` 执行 | 通过可选调度 cursor 能力下传 execution class |
| successor 水位 | `pipeline::HeuristicPolicy` | `pipeline` | current 动图水位改为两帧；不在 Reader 建队列 |
| native WebP demux/canvas/alpha | `media_core::webp` | `media_core` | 单线程 libwebp、TLS 缓冲补丁、预乘 canvas、主动 demux 刷新 |
| Android Surface 尺寸 | Kotlin `SurfaceProducer` 与 Rust blit 重复 | texture bridge composition 在创建/尺寸变化时设置；Rust 仅复制 | 删除每帧 native geometry 设置 |
| RGBA 预乘 | Rust、Android blit、Flutter fallback 多处重复 | `media_core` 解码/合成唯一生成预乘 RGBA | Android/Flutter 仅消费 |
| transition→current task identity | `sessions::LiveCoordinator` 以 replace 取消 | `sessions` lane 保持 active、仅跟进最新 demand | same-key changed 使用 follow |
| 本地文件分块 | `local_media` / `local_media_bridge` / Android bridge | 本地媒体 ingress | 统一 1 MiB；网络 transport 仍 256 KiB |
| libwebp 版本与补丁 | lock + fetch，补丁未自动应用 | native 构建准备脚本 | 引入 deterministic prepare 步骤并由全部 native 构建调用 |
| Reader current page/Presentation | Reader observation 与 presentation | `reader_runtime`/Reader | 不新增 session、transport、artifact 或 decode 所有权 |

## 被否决方案清单

- **关闭预下载、缩小 7/3 窗口、降低 5/3/2 lane 并发**：会掩盖 identity/流量错误并破坏既定播放合同；本轮禁止。
- **Reader 私有图片字节 LRU、Reader 自建 decode/session/prefetch**：制造第二权威来源并越过 Pipeline 所有权；禁止。
- **transition→current 直接取消不可中断 native decode/upload**：已证明会丢弃有效帧、重复创建/退休纹理并在 successor 耗尽后卡住；改为 active 完成后跟进。
- **8 线程 persistent libwebp worker pool / `WebPSetWorkerInterface`**：与两个 Dart decode isolate 形成嵌套并发，切页时放大重型线程和内存压力；按最终 playback 路径改为 libwebp 帧内单线程，仅保留两个 Dart worker。
- **用 source-size 二次缩放、负位移、页面重叠掩盖几何问题**：会裁切内容或引入接缝；只修统一 `height / width` contain 几何与小尺寸对齐。
- **Android 每帧 `ANativeWindow_setBuffersGeometry`**：SurfaceProducer 已拥有尺寸配置；重复配置是生命周期与性能退化。
- **Flutter fallback 再次 alpha 预乘**：native 输出已预乘，二次处理导致半透明变暗。
- **最后一个 cursor 关闭后销毁 decode isolate**：页面重进产生冷启动；进程级 worker 不再由页面 cursor 生命周期控制。
