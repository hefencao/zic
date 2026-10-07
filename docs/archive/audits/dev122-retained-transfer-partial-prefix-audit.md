# dev.122 保留传输、前缀循环与纵向布局审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.121_static-watermark-localized-reader-rebuild.zip`。
- Trace：`zic-debug-trace-2026-08-04T10-40-35.jsonl`、`zic-debug-trace-2026-08-04T10-50-11.jsonl`。
- 用户要求：水位改为 7/5/3/2；partial WebP 已可解至少 30 帧时循环播放；修复切页反复下载、部分图片无法加载和纵向卡顿。

## Trace 结论

- 重复下载样本中，部分页面退出窗口时在 4–5 MiB 处被 `Failure(cancelled)` 终止；没有 validator 的页面重新进入时 `rangeStart=0`，有 validator 的页面则能以 206 续传。
- 失败样本中，JM CDN 页面反复经历三次 task-local retry；新的 demand revision 再次提交同一 failed session，形成 retry storm。大量 promoted 页面也重复产生 `downloadStarted`，但没有真实 source read。
- partial WebP 已支持 unsealed source 解码，缺少的是“已证明可播放前缀”与“容器尚未完整”的循环边界。
- 纵向页面已有源宽高，但 output 尺寸的小幅舍入差仍写入 screen state，重建整个 Scaffold/ReaderView 并可能触发亚像素 anchor correction。

## 实现

- `HeuristicPolicy` 与 `PolicyGuard` 改为 7/5/3/2；refill 顺序为 c3、n2、m2、p2、c5、n3、c7、n4、m3、n5。
- Download demand 移除时只取消 queued task；active transfer 保留到完成。promoted、activeRun、retry pending task 不重复提交。
- 新增最多四轮 session-level download recovery；source 实际增长会清除 retry streak。
- DecodeSession 记录 unsealed source 已成功解出的最大前缀帧数；达到 30 帧后在 `needMoreData` 边界重建 cursor 并循环当前前缀。
- Trace analyzer 增加 partial-prefix loop 与 download-recovery 统计。
- ratio 更新改为 ValueNotifier 局部驱动；已有源比例与 runtime 比例差异小于 1% 时忽略，anchor jump 小于等于 2 logical px 时不执行。

## 额外修复

- 删除 DecodeSession 中重复的 `reset(SourceEpoch epoch)` 声明，新增门禁防止再次生成。

## 未验证

- 当前环境无 Flutter/Dart SDK，新增 owner tests 未实际执行。
- 30 帧循环、active transfer 保留、跨 revision 退避与纵向 build/layout 改善仍需真机 Trace/DevTools 验证。
