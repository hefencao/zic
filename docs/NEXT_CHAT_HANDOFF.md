# dev.108 后续交接

唯一后续基线：`zic_v0.31.0-dev.108_unified-artifact-cache-texture-geometry.zip`。不得使用 dev.107 或更早 ZIP、旧工作树、记忆源码或可变 libwebp tree 覆盖。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/testing/TEST_QUARANTINE.md`
9. `docs/adr/0092-artifact-cache-manager-texture-surface-configuration.md`
10. `docs/audits/dev108-cache-manager-texture-geometry-audit.md`
11. `docs/audits/dev108-validation-results.md`

## 当前主线

1. 设备验证 native texture 是否从持续 status 4 / Flutter fallback 恢复。
2. 验证中央 `ArtifactCacheManager` 的 memory→backend 路由和快速重进命中。
3. 检查 Reader dispose lane-level cancellation、前帧水位和新 current 自动播放。
4. 运行 Flutter analyzer/tests 与 Android debug/release。

## 不可改变

- 下载 7/3；预解码 2/1；只上传 current/transition；lane 5/3/2；
- 两个常驻 Dart decode isolate；libwebp 帧内单线程；current 两个 successor；
- Reader 不拥有 session、transport、artifact cache、decode/upload lane、scheduler 或 texture；
- 普通 response cache 与 Reader artifact partial/promotion 语义不得混成一个 backend；
- README、Architecture、Spec 不写单轮 Trace、验证结果或未验证推断。
