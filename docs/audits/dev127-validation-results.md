# dev.127 Validation Results

## 已执行

- repository、documentation、Dart structure、directive order：通过。
- Pipeline runtime compile boundary：通过。
- dev.75–dev.127 历史 ownership gates：通过。
- quarantine、demand stability、Reader streaming/layout、UI architecture：通过。
- Trace analyzer fixture 与 dev.127 outstanding-buffering 指标：通过。
- Android texture Kotlin stub、Android runtime dependency/Trace：通过。
- Mihon entry、Context、ABI、classloader、read-only、chapter：通过。
- Venera network、native、headers、preflight、bootstrap：通过。
- source binding、登录与设置：通过。
- Python compile、shell syntax：通过。
- 锁定 `libwebp-1.6.0.zip` 的全新 shared host build、incremental 与 loop smoke：通过。

## Trace 基线

对 `zic-debug-trace-2026-08-04T15-00-34.jsonl` 的 dev.127 analyzer 输出：

- `playbackBufferingCount=7`
- `playbackBufferingReadyCount=2`
- `playbackBufferingCompletedCount=2`
- `playbackBufferingOutstandingCount=1`
- outstanding identity 等待约 `3,780,114 µs` 后随 output detach 结束
- mount-to-first-frame 最大值约 `4,033,144 µs`

该结果证明 dev.126 存在未闭合 startup buffering，不是 dev.127 真机结论。

## 验证等级

- startup refill closure、upload-snapshot directed wake、analyzer：Verified-static。
- pinned libwebp host build/smoke：Verified-toolchain。
-新增 Dart owner test：源码已加入，但当前环境无 Dart/Flutter SDK，未执行。
- Android APK 与真机播放：Unverified-device。
