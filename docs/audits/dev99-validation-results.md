# dev.99 验证结果

## 基线与输出

- 唯一基线：`zic_v0.31.0-dev.98_libwebp-archive-exact-patch.zip`。
- 输出版本：`0.31.0-dev.99`；App：`0.31.0+99`。
- 中文提交标题：`增加前帧端到端耗时链并恢复本地 artifact 1 MiB ingress`。

## 设备 trace 事实

输入 `zic-debug-trace-2026-08-03T06-09-41.jsonl` 共 782 条、257,607 bytes：

- 旧版导出只有 31 个 `frameDecoded` 桶和 24 个 `framePresented` 桶，均被时间窗口合并，不能逐 frame 关联；因此用 dev.99 analyzer 分析旧 trace 时 `framePipelineTiming events: 0` 是预期结果。
- 已见 native decode 约 27–60 ms，而 Android present 往返约 116–571 ms；旧 `bridgeMicros` 无法区分平台 queue、retain/blit/schedule/replace、主线程 result dispatch 与 Dart channel dispatch。
- page 11–15 的 mount-to-first-frame 分别约 915 ms、1246 ms、152 ms、271 ms、1099 ms。
- promoted artifact 读取仍以最大 262,144 bytes 分块：5.7–5.8 MiB 需 22–23 chunks，18–21 MiB 需约 70–80 chunks；完整 stream 为约 0.96–2.46 s。dev.99 将该本地读取改为 1 MiB，网络 transport 仍为 256 KiB。
- 发现一次 decode `taskFailed`；旧 trace 没有 lane queue/execution/task elapsed。dev.99 的失败事件会补齐这些字段。

运行 `python3 tool/analyze_frame_pipeline_trace.py /mnt/data/zic-debug-trace-2026-08-03T06-09-41.jsonl` 的旧 trace 摘要：

```text
framePipelineTiming events: 0
source reads: 13
stream p50=1,975,207us, p95/max=2,462,833us
firstChunk p50=119,968us, p95/max=307,647us
task failures: 1 decode
```

## 错误报告处理

- tiny raster/WebP filter：修复产品 `RasterPlan` 的 renderer-upscale 判定；tiny intrinsic frame 仍不交给 codec 放大，renderer 使用 nearest-neighbour。
- Debug Trace build 通知：保留 build 后 deferred notification，测试改为检查 build 期间未通知且下一次 pump 后恰好一次。
- Reader 控件与自适应分类：没有下载 callback 时不伪造下载按钮；动画分类必须来自 metadata/runtime 的实际证据，测试不再用单个 hint 冒充确认。
- Library UI：章节打开先持久化已读；测试使用稳定 screen key，并允许标题在 AppBar 与正文中按产品设计出现两次。
- Source Browser：refresh in-flight future 先原子发布再执行，避免初始加载与 pull refresh 重复；刷新元数据可以持久化漫画但不得下载章节正文。测试 fixture 显式启用来源/书架，不再依赖生产默认状态。
- 仅供旧测试使用的 `comicDetailsRetryKey` 已删除，测试改用生产实际 retry body key。

## 已执行检查

通过：

- repository structure、Dart structure、directive order、Pipeline compile boundary；
- dev.75–dev.99 全部 ownership/static gates；
- `framePipelineTiming` analyzer fixture；
- Android runtime dependency/Trace、Mihon entry/context/ABI/classloader/read-only/chapter、Venera network/native/headers/preflight/bootstrap、Reader/Pipeline/UI/source binding/settings 合同；
- shell syntax和 Python `py_compile`；
- 从仓库锁定 `libwebp-1.6.0.zip` 在全新外部依赖目录完成 shared host CMake/Ninja 构建，以及 incremental/loop Animated WebP smoke。

`tool/check.sh` 的单次运行受执行窗口限制，在 Android Trace 合同之后超时；从下一项分组续跑全部通过，没有把超时记录为测试通过或失败。

## 当前环境限制

当前容器没有 Flutter/Dart SDK、Cargo/rustc、Gradle、Android SDK/NDK 与 ADB。因此错误报告中的 Flutter tests、`flutter analyze`、Rust build、Android debug/release 和真机播放未在本环境执行；静态 gate 与源码级修复不能替代这些验证。

## 完整 ZIP 复验

候选完整 ZIP 独立解压后已执行：

- `unzip -t`：通过；
- 禁止生成物扫描：未发现 `.git`、`.dart_tool`、`build`、`.gradle`、`.deps`、`target`、`__pycache__`、`.pyc`、`.class`、`.rej`、`.orig`；
- repository/Dart structure/directive order/Pipeline compile boundary：通过；
- dev.79、dev.96–dev.99 与 analyzer fixture：通过；
- 从解压副本内保留的 6,776,584-byte `libwebp-1.6.0.zip`，在全新的外部依赖目录重新完成 shared host build 和 incremental/loop Animated WebP smoke：通过。

最终 ZIP 只在此验证记录写回后重新生成；重新生成后再次执行压缩完整性、生成物扫描与关键门禁。
