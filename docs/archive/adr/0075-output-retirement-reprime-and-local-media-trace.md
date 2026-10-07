# ADR 0075: 输出回收后的解码重置与本地媒体链路诊断

## 状态

Accepted for `0.31.0-dev.91`.

## 背景

设备 Trace 显示页面首次进入时可以完成 `frameDecoded -> frameUploaded -> framePresented -> firstFrameReady`，但离开页面后再返回，DecodeSession 会在 `depth=0` 下反复进入 `decoding -> ended`，UploadSession 停在 `waitingFrame`，页面直到销毁也没有新的 `firstFrameReady`。

原因是上传会消费 FrameHolder 中的 decoded frame。页面离开 current/transition 上传窗口后，UploadSession 退休 renderer output；但页面仍可能留在前 2/后 1 的 decode window，因此 DecodeSession demand 没有 detach，已经位于 EOF 的 cursor 也没有重建。下一次回页只会继续读取 EOF。

## 决策

1. UploadSession 是 renderer output 生命周期的唯一所有者。它在 demand detach 或 frame budget trim 真正退休 output 时，原子通知绑定的 DecodeSession。
2. DecodeSession 只有在 FrameHolder 已空时才将 cursor 标为需要重建；仍持有预解码 frame 时不丢弃该 frame。
3. LiveCoordinator 在 upload demand detach 后，仅当 decode demand 仍存在且 decoder 确实被重置时，提交同 identity 的 decode follow-up。Upload demand 遇到 `waitingFrame` 时也唤醒现有 decode demand。
4. 动画正常 frame advance 不使用该重置；它继续从下一帧推进。只有整个页面 output 被退休时，回页播放才从该页面解码生命周期的起点重新建立。
5. 不扩大 current/transition upload window，不保留整章 texture，不在 Reader/App 创建私有图片字节或 ImageProvider LRU。
6. Trace 补充以下权威阶段：
   - `sourceRead`：persistent artifact、session artifact、本地 file、Android document、插件资源或远程来源；聚合 open、首块、总流时长、块数、块尺寸及最大块间停顿。
   - `frameDecoded`：解码耗时、输入长度、尺寸、帧字节和帧时长。
   - `frameUploaded`：上传耗时、输入/输出字节、尺寸和 renderer。
   - `framePresented`：实际呈现耗时和播放状态。
   - `playbackFrameDue`：帧到期时相对 deadline 的迟到量。
   - `pageOutputReleased`：回收原因、output 字节、present claim、decode 深度和是否重建。

## 被否决方案

- 保留所有已看页面的 texture：违反只上传 current/transition，并会将显存随章节长度增长。
- 在 Reader 页面 Widget 中缓存 decoded bytes/ImageProvider：形成与 Pipeline、DownloadSession 和 artifact 竞争的第二权威来源。
- 页面离开即完整 detach DecodeSession：会破坏前 2/后 1 预解码窗口，并增加无必要重复解码。
- 缩小预下载/预解码窗口掩盖问题：不修复 EOF cursor 生命周期错误，并违反既定 7/3、2/1 策略。
- 依赖页面 Widget keepAlive：只能偶然延后 dispose，不能修复 output 被预算或策略回收后的资源状态。

## 影响

- 静态图和有限动画回页时可从相同 encoded source/artifact 重建首帧。
- 非当前页面不新增长期 renderer output；显存策略不变。
- 新 Trace 能区分本地 provider/文件读取慢、artifact 恢复慢、解码慢、上传慢、呈现慢或动画 deadline 迟到。
- 设备仍需重新导出 Trace 验证实际 Android 解码、上传和播放耗时。
