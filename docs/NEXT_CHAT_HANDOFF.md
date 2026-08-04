# dev.122 后续交接

唯一后续基线：`zic_v0.31.0-dev.122_retained-transfer-partial-prefix-playback.zip`。

## 必读

1. `AGENTS.md`
2. 本文件
3. `docs/DOCUMENTATION_POLICY.md`
4. `docs/ARCHITECTURE.md`
5. `docs/SPEC.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/IMPLEMENTATION_PLAN.md`
8. `docs/adr/0106-retained-transfer-partial-prefix-playback.md`
9. `docs/audits/dev122-retained-transfer-partial-prefix-audit.md`
10. `docs/audits/dev122-validation-results.md`

## 下一份 Trace

### 动画水位与 partial prefix

- 动画 c/n/m/p 最大水位应为 7/5/3/2；权威静态页一帧即满足；
- 未封缄 WebP 已证明至少 30 帧可解后，应出现 `animationLoop partialPrefix=true`；
- prefix 循环期间 source 下载应继续增长，后续循环可解帧数不应倒退。

### 重复下载与失败恢复

- active partial 离开窗口不应被取消；若来源不支持安全 Range，重新进入也不应从 0 重开；
- promoted/active/queued/retry-pending session 不应因 revision 重复 submit；
- `download-recovery` 应跨 observation revision 保留次数与退避，不应形成三次尝试后立刻重置的失败风暴。

### 纵向滚动

- 记录 build/layout、ratio 更新、anchor restore 与 jumpTo 修正量；
- 已有 PageAsset 尺寸时，小于 1% 的 runtime ratio 差异不应触发更新；
- 小于 2 logical px 的 anchor 微调不应 jumpTo。

## 不可改变

- 不拆分静态/动画 refill 状态机；静态页一帧即满足，动画为 7/5/3/2；
- 下载窗口前 7 / 后 3；
- remote/global 并发 5，本地 bucket 2；
- decode/upload lane 3/2；
- 静态 96 MiB 选择预算与 128 MiB output budget；
- last keep；
- DownloadSession、Pipeline、FrameBudget 与 texture 的现有所有权；
- active transfer 保留不得演变为 Reader 自有后台下载器。
