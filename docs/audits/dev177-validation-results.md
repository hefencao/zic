# dev.177 验证结果

## 基线与输入

- 唯一代码基线：`zic_v0.31.0-dev.176_response-abort-artifact-crc-hotpath.zip`。
- 当前发行候选：Source `0.31.0-dev.177`，Android `versionCode=177`。
- 设备输入：`zic-debug-trace-2026-08-09T00-50-27.jsonl`。
- 只读参考：文件库权威 `vibevenera-master.zip`；未将参考工程作为代码基线，也未复制其 UI/ownership facade。
- 当前环境有 Python、Git、Kotlin/JVM、Node；没有 Dart/Flutter SDK、Cargo/Rust和完整 Android SDK/NDK，因此不宣称 Dart/Flutter行为测试、Rust测试、`flutter analyze`或 APK build已执行通过。

## Trace 与 VibeVenera 对照结论

- Trace 中共有28次 `retained-background` priority migration。既有 receiving task在 logical detach 后降为 priority=0；同一设备样本中也存在 retained identity 后续重新进入 demand 并原位提权的情况。仅凭“离窗后仍在下载”不能推导应立即 cancel。
- `vibevenera-master` 的 `StreamingSessionCoordinator._reconcileDownload()`明确：无 demand 时，已经 `receiving` 的 transport继续保留；queued/未建立 transport才 retire。其 download task声明 `retainWhenInactive=true`。
- VibeVenera scheduler在真正 high-priority/current pressure到来时才抢占最低rank receiving；即使 normal+reserved handoff已饱和，也继续请求另一个低rank victim退出，但原task真实退出前不释放permit。
- 因此最初 dev.177 候选“page-window detach即精确cancel active transfer”属于退优化：快速前后切页会反复断线、重新resolve/request，非Range来源甚至从零重下。该候选在发行冻结前已撤销，未作为最终dev.177交付。
- dev.175/176热路径修复继续有正向设备证据：467个 `bytesCommitted` 样本中 `nativeIngressMicros`中位48µs、p90约124µs；`artifactWriteMicros`中位96µs、p90约191µs。当前证据不支持回滚 native source锁拆分、full-response cancellation或 CRC seal-boundary方案。

## 最终下载生命周期与抢占模型

- `LiveCoordinator`恢复 VibeVenera语义：active receiving离开 encoded窗口时迁移为 `retained-background=0`；queued undemanded task可 `cancelQueued`。再次进入窗口时同一active task只更新priority，不创建第二个writer/transport。
- dev.174 bounded saturated preemption保留：current真实竞争时可推动尚未cancel的最低rank receiving退出；normal5 + reserved1不变，cancel只是退出请求，真实task完成前不释放permit。
- ZIC额外存在 Venera单上下文 runtime gate。dev.177把同一 pressure-only原则下沉到该gate：只有 scheduler-controlled active invocation明显低于后到 current时才请求 cancel；普通 logical detach本身不触发 Venera cancel。`runtime-request-cancelled`映射为 domain `ErrorCode.cancelled`。
- dev.175 TaskControl贯穿 source/runtime、native source锁临界区拆分继续保留；dev.176 response body lifetime abort与artifact checksum off-hot-path继续保留。
- 回归源码覆盖“active nonresumable transfer detach→priority 0→快速返回→priority 1000且 `transport.opens==1`”，防止前后切页变成 cancel/reopen/re-download 抖动。

## 下载管理 Route-First

- Home打开下载管理时传入已有 `ChapterDownloadSnapshot` projection与 `WholeComicQueueSnapshot`；新route第一帧不等待 durable/cache scan。
- `DownloadManagerScreen.initState()`不再用 `scheduleMicrotask(_reload)`或首帧前等待 whole queue ready；首帧之后再通过 `addPostFrameCallback`进行后端校正。
- durable chapter刷新使用 `ChapterDownloadService.inspectMany()`，不再对所有entries逐个 `Future.wait(inspect)`。
- 新 Flutter widget regression使用阻塞 `inspectMany` fixture，要求后台refresh未完成时 `downloadManagerScreenKey`和初始chapter snapshot已经渲染。当前环境无Flutter SDK，因此该行为测试未执行，只通过静态/结构gate确认已纳入源码。

## 补丁债务清理

- 最初 exact-detach-cancel候选及其“删除dev.174 saturated preemption”的改动已撤销；ADR 0106/0107/0157与dev.112/122/123/174 gates恢复到由设备证据和VibeVenera源码支持的 retained-receiving / pressure-preemption语义。
- dev.81 gate只迁移dev.176新增的唯一 loopback `HttpServer` response-cancellation回归，不把 generic不稳定网络fixture放回历史测试。
- 没有增加 debounce timer、第二download scheduler、第二transport或额外缓存状态机。

## 已执行验证

- `check_dart_structure.py`：342 Dart files / 129 test files。
- directive-order、documentation responsibility/current-documentation gates。
- 当前 `test_dev*.py` 共102个；除dev.98因当前基线缺 pinned libwebp archive排除外，其余101个均分段明确通过。
- Reader streaming、Pipeline demand stability、source-resource atomic binding、UI architecture。
- Mihon payload Context Kotlin compile、ABI、split classloader、chapter contract。
- Venera bootstrap、Reader preflight、network、native-binary contracts。
- Android runtime dependency、texture Kotlin compile、native header、Python bytecode与shell syntax检查。

## Repository check

`python3 tool/check_repo.py`仍只停止于：

`third_party/source_archives/libwebp-1.6.0.zip` 缺失。

这是 dev.176基线继承缺件，本轮未从旧包补入。

## 发行回放

从全新dev.176完整ZIP生成候选Patch并实际执行 `git apply --check --index` / `git apply --index`。候选Patch包含20个实际修改/新增文件；工作树与回放树均为1150个发行文件：missing=0、extra=0、content diff=0、executable-bit diff=0。本文件自此冻结；随后重新生成正式Patch并第二次从全新dev.176回放。最终交付仅在冻结后的正式结果仍为1150 / 0 / 0 / 0 / 0时成立。
