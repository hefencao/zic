# dev.97 Reader 50% 播放交接与诊断 Trace 审计

## 问题清单

### 编译错误

1. `ArtifactCacheTransport` 在闭包内调用 `ArtifactCacheStreamStore.openArtifactStream`，依赖 Dart 对无关 interface 的隐式提升；实际编译器仍将局部值视为 `ArtifactCacheStore`。
2. `DecodeSession` 在条件表达式中直接访问 `FrameDecodeTiming` 的 timing getter，实际静态类型仍为 `FrameRef`。
3. `Ingress` 在闭包中直接调用 `ExpectedLengthEncodedSource.reserveExpectedLength`，实际静态类型仍为 `EncodedSource`。
4. `prepare_webp.sh` 直接调用 `patch`；输入 `vp8_dec.c` 的换行风格不同时，补丁可能前两段成功、第三段失败并留下 `.rej` 和半应用 tree。

### 产品错误

1. `PageView.onPageChanged` 在 50% 边界把 observation 强制改成整数页。该瞬时 observation 没有 outgoing target，Pipeline 因此真实移除旧页 upload demand；旧 texture 被 `pageOutputReleased(reason=demand-detached)` 退休，紧随其后的 fractional scroll observation 又把旧页作为 transition 加回，造成黑屏和重新上传。
2. `ViewportResolver` 默认 dominant threshold 为 0.6，离散翻页在 40%–60% 区间把两页同时冻结；这不符合“超过 50% 旧页暂停、新页开始”的交接合同。
3. Pipeline reconcile 可在 viewport observation 之后异步创建 UploadSession；若不重投影现有 viewport，新 current/transition session 可能错过首次 freeze/resume，表现为切页后动画不启动，回切才恢复。

### 性能问题

1. 设备 Trace 共 6486 条、4,147,260 bytes；高频 frame/decode/upload/scroll 事件与超长本地 locator identity 重复占用绝大部分体积。
2. 原导出环只限制条数，不对高频权威投影做时间桶摘要。单次播放可产生数百条相同 identity 的 `uploadState/frameUploaded/framePresented`。
3. 长本地 `content://` identity 在每条事件重复输出。它只需要稳定相关性，不需要在每条 Trace 中重复完整路径。

### 测试错误与缺口

1. Reader 回归只断言页面 host 未销毁，没有断言跨 50% 后 observation 仍同时携带新 current 与旧 transition。
2. Viewport 测试仍把 50%/50% 视为 freeze，而非稳定页接管。
3. 没有验证异步创建的 UploadSession 会立即重投影 viewport。
4. libwebp 补丁 fixture 只使用 LF，并依赖 `patch --dry-run`，未覆盖 CRLF 与幂等重跑。
5. Debug Trace 测试仍把导出环称为 raw，且没有验证高频合并、错误保留、范围摘要和长 identity 压缩。

## 所有权清单

| 状态、资源或命令 | 当前所有者 | 正确所有者 | 本轮处理 |
|---|---|---|---|
| PageView fractional position、stable page | `reader::ReaderView` | `reader::ReaderView` 仅投影为 `ReaderObs` | `onPageChanged` 读取真实 fractional position，不创建整数 targetless observation |
| current/transition 角色与 upload demand | `pipeline::RoleResolver/PipelineController` | 同左 | 保持；Reader 不保活 texture，也不扩大上传窗口 |
| 50% 播放主导页 | `sessions::ReaderBinding` + `pipeline::ViewportResolver` | 同左 | 默认阈值改为 0.5；稳定页在 50% callback 后接管 |
| UploadSession freeze/resume | `sessions::PlaybackCoordinator` | 同左 | runtime 新建/更新 upload snapshot 后调用 binding 的只读 viewport 重投影 |
| texture/output 生命周期 | `sessions::UploadSession` / platform presenter | 同左 | 只防止错误 demand detach；真正移除 demand 时仍按依赖顺序退休 |
| Trace 事件事实 | 各所有者通过 `telemetry::TraceSink` 发出 | 同左 | 错误和关键生命周期事件不参与导出合并；有界容量淘汰必须显式计数 |
| Trace identity 脱敏与稳定 hash | `telemetry` | `telemetry` | 长 identity 压缩为稳定 hash+长度摘要 |
| Debug 导出时间桶与 UI 过滤 | `apps/app::DebugTraceLog` | App 的诊断 projection | 合并高频事件并保存计数、首尾和 min/max；不成为调度状态来源 |
| libwebp prepared tree | `tool/prepare_webp.sh` | build tooling | 用确定性 Python transformer 应用 pinned patch；media/runtime 不感知脚本 |
| VP8 TLS workspace | patched libwebp on decode isolate OS thread | libwebp patch | 保持一线程一份 workspace；不恢复额外 worker pool |

## 被否决方案清单

1. **Reader 保存旧 texture/最后一帧覆盖黑屏**：建立第二权威 output 生命周期，掩盖错误 demand detach，否决。
2. **把 previous/next 全部加入 upload window**：扩大 texture 与上传开销，绕过 current/transition 所有权，否决。
3. **把 dominant threshold 提高或在 50% 附近冻结两页**：直接违背用户要求的 50% 播放交接，否决。
4. **通过关闭预下载、缩小 7/3 或 2/1、降低 lane 并发减轻问题**：掩盖生命周期错误，否决。
5. **在 `onPageChanged` 延迟固定毫秒再发送 observation**：依赖设备时序且会制造命令竞争，否决。
6. **重新取消 transition 的不可中断 native decode/upload**：会丢弃有效帧并重复退休 texture，延续已证明退化的 dev.95 前行为，否决。
7. **删除 frame/decode/upload Trace 或只保留错误**：丢失权威性能诊断，否决；改用有界时间桶摘要。
8. **在 telemetry 中保存完整本地 locator 以便人工阅读**：体积和隐私成本过高；稳定 hash 已足够关联，否决。
9. **继续依赖 GNU patch fuzz**：可产生半应用 prepared tree，否决；使用版本锚定且幂等的 transformer。
10. **修改 Mihon/VibeVenera 参考源码**：本轮问题属于 ZIC Reader/Pipeline/诊断链，与插件协议无关，禁止。
