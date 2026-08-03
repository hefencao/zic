# dev.105 后续交接

唯一后续基线：`zic_v0.31.0-dev.105_direct-promoted-artifact-hot-cache.zip`。不得使用 dev.104 或更早 ZIP、旧工作树、记忆源码或可变 libwebp tree 覆盖。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/testing/TEST_QUARANTINE.md`
9. `docs/adr/0089-direct-promoted-artifact-read-and-hot-cache.md`
10. `docs/audits/dev105-direct-artifact-read-cache-audit.md`
11. `docs/audits/dev105-validation-results.md`

## 当前主线

1. 采集 dev.105 首次进入、快速重进和未稳定切页 Trace。
2. 检查 `artifactReadMode`、`artifactMaterializeMicros`、memory hit/join、first chunk 和完整 stream。
3. 确认 persistent cache hit 不再执行多余的 DownloadSession restore/prefix/index 状态链，也不回退原始 `content://`。
4. 继续验证 retained cursor、新 current 自动播放和 successor 预解码。
5. 运行 Flutter analyzer/tests 与 Android debug/release。

## 不可改变

- 下载 7/3；预解码 2/1；只上传 current/transition；lane 5/3/2；
- 两个常驻 Dart decode isolate；libwebp 帧内单线程；current 两个 successor；
- Reader 不拥有 session、transport、artifact cache、decode/upload lane、scheduler 或 texture；
- README、Architecture、Spec 不写单轮 Trace、验证结果或未验证推断。
