# ADR 0076: 静态播放判定与 successor-safe 输出替换

## 状态

Accepted for `0.31.0-dev.92`.

## 背景

用户在 dev.91 上明确执行了静态/动画页面前后切换并重新导出 Trace。该 Trace 中共有 6 次 `pageHostMounted`，只有 3 次 `firstFrameReady`；仅有的 3 次 `framePresented` 均携带 `durationMicros=0`，但随后仍各自产生 `playbackFrameDue`。之后对应 DecodeSession 在空缓冲上持续 `decoding -> ended`，UploadSession 长期 `waitingFrame`，回页没有新的首帧。

这证明 dev.91 只修复“upload demand detach/frame budget 退休 output 后重建 cursor”的路径，并未覆盖 UploadSession 自身的播放推进：零时长静态帧被错误启动 timer，timer 到期后旧实现会先删除当前 output，再尝试取得下一帧。静态图没有下一帧；有限动画在最后一帧也可能没有 successor，于是有效 output 被提前移除，页面退回 loading。

## 决策

1. `PlaybackTimer.start` 对非正时长必须保持 idle，不创建立即到期的 timer。
2. 当解码元数据已确认 `complete && frameCount <= 1` 且 output duration 为 0 时，UploadSession 将该 output 视为权威静态帧；它只能由 upload demand detach、frame budget、reset 或 dispose 退休。
3. 动画帧到期时，UploadSession 不再先删除当前 output。它进入 `awaitingSuccessor`：
   - 当前 output 继续可见；
   - `preparedDepth` 对 decoder 投影为 0，促使现有 decode demand产生下一帧；
   - 下一帧成功上传后原子替换并退休旧 output。
4. 若 decoder 在等待 successor 时进入 `ended` 且 holder 为空，有限动画完成；UploadSession 清除等待状态、保留最后一个 output，并产生 `playbackCompleted` Trace。
5. source 仍可能增长时，旧 output 保持可见；后续 source revision 唤醒同一 DecodeSession 后再上传 replacement。失败也不得为了显示 loading 而提前销毁已有 output。
6. 这不是扩大上传窗口或页面缓存：同一 UploadSession 始终最多持有一个可呈现 output；只改变 replacement 的提交顺序。
7. 错误报告中的 `Stream.toList(growable:)` 只修测试 API；authoritative stitched viewport 的失败由修正测试根节点 tight-constraint fixture 解决，不更改产品几何。

## 被否决方案

- 静态图使用任意最小时长反复尝试下一帧：会制造无意义 EOF 调度，并掩盖静态/动画元数据。
- 动画到期先清空 output，再等待下一帧：网络、解码或有限 EOF 时会闪回 loading，正是本轮根因。
- 永久保留所有已看页面纹理：违反 current/transition 上传边界并导致显存随章节增长。
- 在 Reader Widget 中保存上一帧：形成与 UploadSession 竞争的 output 所有者。
- 仅把 loading Widget 改为继续显示旧图：Presentation 无权判断 output、cursor 与 successor 生命周期。

## 影响

- 静态图片的零时长帧不再进入播放调度。
- 动画下一帧尚未准备好时继续显示当前帧，不闪回 loading。
- 有限动画在 EOF 时冻结最后一帧。
- 页面真正离开上传窗口或被预算裁剪时，仍使用 ADR 0075 的 output-loss re-prime；7/3、2/1、current/transition、5/3/2 和 256 KiB I/O 均不变。
- 新的 `playbackCompleted` 与 `framePresented.playbackScheduled/authoritativeStatic/awaitingSuccessor` 字段可区分静态判定、successor 等待与有限动画完成。
