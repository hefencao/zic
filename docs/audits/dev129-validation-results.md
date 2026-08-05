# dev.129 验证结果

## 修复前设备证据

输入：`zic-debug-trace-2026-08-04T23-49-35.jsonl`

- `firstFrameReadyCount=27`
- mount-to-first-frame：p50 65,819 µs，p95 263,029 µs，max 269,800 µs
- texture presentation 57 次，reuse 54 次
- reused bridge ≥100 ms：2 次
- reused bridge：p50 891 µs，p95 10,675 µs，max 207,630 µs
- reused schedule queue：p50 144 µs，p95 11,529 µs，max 160,480 µs
- `playbackBufferingOutstandingCount=0`
- 旧 Trace 不含 worker placement 字段，因此状态计数为空

## 已执行

- repository/documentation/Dart structure/directive order
- Pipeline runtime compile boundary
- dev.129 专项门禁
- Trace analyzer fixture
- native header contract
- Python compile

## 待执行

- Flutter analyze 与 Dart/Flutter owner tests
- Cargo/Rust Android target build
- Android release APK
- 长后台设备 Trace：fresh used texture lifecycle、performance-core placement、前 15 帧 decode/present
