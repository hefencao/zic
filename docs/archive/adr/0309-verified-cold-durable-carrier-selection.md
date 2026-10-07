# ADR 0309：Verified cold durable carrier selection

- 状态：Superseded
- 日期：2026-09-10
- 影响：历史兼容层；主路径已由 ADR 0310 的 direct canonical physical ownership 取代

## 被取代说明

ADR 0310 已将 production hot path 收敛为 `exact page -> canonical PhysicalMediaId`。本文的 carrier ranking 只保留给尚未形成 canonical projection 的旧数据/既存 generation 自然退休，不能再作为新版本复用的主运行时模型。

## 背景

ADR 0209把cross-version cold partial从Home/version warmup复制迁到physical prepare，这是正确的ownership收口；但当时同时规定“exact存在时始终优先”。后续版本复用已统一到composition-owned `VersionPageAuthority`，hot physical acquire也已允许无consumer的短exact retained session在下一次claim时让位于更先进的direct verified carrier。

`zic-debug-trace-2026-09-09T23-51-35.jsonl`暴露了同类现象：verified relation和strong media identity都已成立时，不同版本可各自积累不同长度的physical prefix。审查实现后发现hot路径已在`37c21a1b`修复，但`PartialDownloadHandoff`仍会在durable tier看到任意非空exact后立即返回，导致一个较短cold exact partial永久遮蔽更长verified-equivalent partial或完整READY。该行为也与当前`SPEC.md`中“existing state共同择优”的总规则冲突。

## 决策

1. recoverable session-local artifact仍是当前physical generation的第一物理owner；如果它实际存在正文，继续先恢复它，不把crash-recovery staging与跨版本durable selection混为一层。
2. 仅当session-local artifact证明为空时，`PartialDownloadHandoff`进入durable carrier selection；exact ID与`VersionPageAuthority`提供的direct verified equivalents属于同一个candidate set。
3. durable候选排序固定为：完整READY高于incomplete partial；incomplete partial按已提交长度从长到短；同一authority等级且长度相同，exact优先。这样只在存在严格更强物理state时跨identity复用。
4. metadata只用于廉价排序，不是body proof。最终选中candidate仍必须调用`openPartialDownload()`完成root/locator/length/state物理校验；metadata与open不一致时回退exact + direct equivalents的physical scan。
5. exact胜出时保留其validator与可用的POSIX adoption/READY proof优化；verified-equivalent胜出时继续清空foreign ETag/Last-Modified，完整READY可直接绑定immutable artifact-cache range authority，partial则按既有stream-copy/continuity规则恢复。
6. 本决策不创建target exact durable副本、不late merge两个已存在hot session、不改写历史exact durable record，也不改变显式required-completion最终materialize调用者exact target的语义。
7. NetLane、Reader 3/7、decode/upload/presentation、版本proof形成方式均不变。

## 后果

版本复用的三个consumer现在遵循同一方向：READY cache lookup、cold durable restore与hot physical acquire都只消费direct verified candidate authority，并在已有state中选择更强carrier；“exact”继续表示logical/durable ownership，而不再等价于“无论物理进度如何都必须优先读取这一份”。ADR 0209关于移除warmup copy、prepare边界、validator隔离和禁止late merge的决策继续有效。
