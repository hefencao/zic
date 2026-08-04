# dev.110 后续交接

唯一后续基线：`zic_v0.31.0-dev.110_staged-waterline-last-frame-first-surface.zip`。不得使用 dev.109 或更早 ZIP、旧工作树或陈旧 Android `.so`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0094-staged-decode-waterlines-last-output-retention.md`
9. `docs/audits/dev110-staged-waterline-last-frame-audit.md`
10. `docs/audits/dev110-validation-results.md`

## 下一步 Trace

重点检查：

- `decodeRefill` stage/role/depth/target；
- `lastFrameKept` 与旧 current 是否仍 `pageOutputReleased:demand-detached`；
- frame 0 `presentedAtMicros` 到 `firstFrameReady` 的间隔；
- last→current 后 playback 是否恢复；
- Reader dispose 的 coordinator 长尾。

## 保持边界

下载 7/3、lane 5/3/2、两个常驻 decode isolate、libwebp 帧内单线程，以及 Reader 不拥有 cache/session/transport/texture。水位由 Pipeline/Sessions 所有，last output 不由 Widget 截图替代。
