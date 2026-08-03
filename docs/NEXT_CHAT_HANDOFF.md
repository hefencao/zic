# dev.109 后续交接

唯一后续基线：`zic_v0.31.0-dev.109_cache-tier-native-build-identity.zip`。不得使用 dev.108 或更早 ZIP、旧工作树或陈旧 Android `.so` 覆盖。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0093-cache-tier-internalization-native-build-identity.md`
9. `docs/audits/dev109-cache-native-abi-audit.md`
10. `docs/audits/dev109-validation-results.md`

## 下一步

1. 必须重新运行 Android native build，不得复用旧 jniLibs。
2. 完成 Flutter analyzer/tests 和 Android debug/release。
3. 采集设备 Trace，确认 platform presentation、surface reconfigure 与 fallback。
4. 若仍卡顿，再按 current source/decode/upload/present 的新 Trace 继续，不得退回增加 cache facade。

## 不可改变

下载 7/3、预解码 2/1、current/transition upload、lane 5/3/2、两个常驻 decode isolate、libwebp 帧内单线程、current 两个 successor，以及 Reader 不拥有 cache/session/transport/texture。
