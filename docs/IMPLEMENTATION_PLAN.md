# zic Implementation Plan

本文件只列未完成工作。

## P0：Android native 产物闭环

- 在 Android 环境运行 `tool/build_android_native.sh debug` 与 `release`；
- 确认 build marker 与 retain/release/blit JNI symbols；
- Gradle debug/release 必须拒绝旧或缺失 `.so`；
- 设备 Trace 确认缺失 configure JNI 错误消失，platform presentation 恢复。

## P0：前帧与重进设备验证

- 比较首次进入与快速重进的首帧、前 12 帧、fallback、surface reconfigure 和 dispose；
- 确认 reconfigure 只发生在首次/resize/recreate 或一次 lock retry；
- 继续定位剩余 decode failure 与新 current 自动播放问题。

## P0：Flutter/Dart 闭包

运行 analyzer、downloads/sessions/pipeline/texture package tests 和 App 目标 tests；失败按产品、测试和环境所有者处理。

## P1：解除 Source Browser quarantine

为 Q-001 至 Q-003 建立直接 facade/widget harness。

## 每轮收尾

引用搜索、可用门禁、Status/Handoff/CHANGELOG/audit、干净打包与 ZIP 独立解压。
