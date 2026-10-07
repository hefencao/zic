# dev.138 验证结果

## 输入与参考

- 唯一代码基线：`zic_v0.31.0-dev.137_home-cover-primary-current-flow-pressure.zip`。
- 只读参考：文件库中的 VibeVenera `STREAMING_IMAGE_PIPELINE_ARCHITECTURE.md`。
- 用户设备现象：进入 Reader 后目标页切换受阻，表现为需要等待第一张图片完整下载。

## 代码结论

- dev.137 `DownloadFlowGate` 同时依赖 current role、source bucket 与 decode holder depth，是独立于 NetLane 的第二套网络资格调度。
- 同源 transition/next transport 在 current depth≤1 时不能读取下一块，只有 current depth≥3 才释放。
- 解码 refill 同时固定 `c>2` 先于 transition `n>1`，形成网络和解码两层串行门槛。
- Reader PageView 未设置首帧锁；target coverage 0.15 时已进入 transition。

## 实现验证

- `DownloadFlowGate`、`DownloadChunkPermit`、`beforeReadChunk`、`_refreshDownloadFlowPressure`、`downloadFlowPressure` 已从生产代码和 owner tests 删除。
- DownloadJob 继续保留 resume、partial、首批 16 KiB/后续 64 KiB 合并和 writer lease，不读取页面角色。
- transition depth=0 时先返回 `t>0`、target watermark=1；transition 已有一帧后 current `c>2` 恢复为首个 staged refill。
- NetLane current reserved slot、priority migration、preemption 与稳定 7/3、7/5/3/2、5/3/2 均保持。

## 已执行并通过

- repository、documentation、Dart structure、directive order、Pipeline compile boundary；
- dev.75–dev.138 历史静态门禁；
- dev.137 retained home/coalescing 与 dev.138 switch-independence 专项门禁；
- Trace analyzer fixture 与 test quarantine；
- Android runtime/Trace、Kotlin texture stub；
- Mihon entry、payload、ABI、classloader、read-only、chapter；
- Venera network/native/headers/preflight/bootstrap；
- Reader/Pipeline/UI/source binding/login/settings 合同；
- native header；
- 锁定 libwebp 1.6.0 的 shared host build、incremental 与 loop smoke。

## 未验证

当前环境没有 Flutter/Dart SDK、完整 Android SDK/NDK 和 ADB，因此未声称：

- `flutter analyze` 或新增 Dart owner tests 已实际运行；
- Android APK 已构建；
- 目标设备切页回归已完成真机验证。
