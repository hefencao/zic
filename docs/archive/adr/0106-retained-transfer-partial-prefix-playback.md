# ADR 0106：保留活动传输与 Partial WebP 前缀循环

状态：Provisional

## 背景

设备 Trace 显示两类相互独立的问题：

1. 页面离开 7/3 窗口时，Coordinator 会取消已经开始的下载任务。支持 Range 且 validator 完整的来源可以续传；没有安全 validator 的来源再次进入窗口时只能从 0 开始，形成切页反复下载。
2. unsealed WebP 已经能够连续解出大量帧，但遇到尚未下载到的下一帧后仍进入 `waitingSource`。在下载速度低于播放速度时，用户会看到停顿，而已解出的可播放前缀没有被循环利用。
3. 同一远程资源的三次 task-local retry 会被新的 policy revision 重新提交，形成无上限的失败风暴。

## 决策

- 动画 staged 水位调整为 c/n/m/p = 7/5/3/2；静态页一帧满足规则保持。
- 页面退出窗口时只取消尚未开始的 ranked task。已经持有 authoritative writer/run 的传输继续完成；Reader dispose 仍取消属于该 Reader 的任务。
- promoted、activeRun、已排队或处于 session-level retry cooldown 的 DownloadSession 不重复提交。
- task-local retry 耗尽后，Coordinator 记录跨 revision 的 capped retry round；普通 observation 变化不能重置该状态。真实 source 字节增长会清除 retry streak。
- unsealed WebP 实际连续证明至少 30 帧可解后，若下一帧返回 `needMoreData` 且 holder 已耗尽，则重建同一 source epoch 的 cursor，从 frame 0 循环当前前缀。下载继续增长，下一轮 cursor 可以自然解到更远帧。
- 前缀循环不是容器权威 EOF，不写入完整 animation classification，也不修改 Rust/JNI ABI。
- 已有 PageAsset 宽高时，runtime 输出比例小于 1% 的差异不覆盖布局元数据；aspect-ratio 更新仅重建 ReaderView 子树。

## 不变项

- 下载窗口前 7 / 后 3；global/remote bucket 5，本地 bucket 2。
- decode/upload lane 3/2；两个常驻 Dart decode isolate；libwebp 帧内单线程。
- DownloadSession 仍是 writer、partial、resume、epoch 与 source ingress 的唯一所有者。
- 静态 output 驻留与 128 MiB FrameBudget 不变。

## 风险

- non-resumable active transfer 在快速跨页时会继续占用一个网络槽；这是避免从 0 重下的必要代价，需由后续 Trace 比较 current 等待与重复字节量。
- 30 帧为临时阈值，应通过设备帧率、帧时长和网络速度验证后再配置化。
- runtime ratio 超过 1% 时仍可触发 anchor correction；设备端仍需验证纵向回拉和 build/layout 长尾。
