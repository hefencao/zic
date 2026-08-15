# dev.298 static presentation demand-gap 审计

## 触发
用户在dev.297真机明确反馈“抖动很明显，不是一两个px”，并提供`zic-debug-trace-2026-08-15T10-01-21.jsonl`。这直接否证dev.297以subpixel/pixel-snap量级解释主抖动；不得通过扩大0.5px阈值继续补偿。

## 10:01 Trace事实
- 共3426条事件；`pageLayoutSnapshot` 450条，继续没有支持大幅Sliver box跳变的新证据。
- `framePipelineTiming`共38次，全部是static frame 0。初始化后大量再次presentation为`platformResidentReuse=true`，blit/schedule/channel均为0。
- identity `<-564c34595f9ca003,254>`首次current present后又以transition resident reuse 9次；`<-7ced3512dc3d6999,254>`同样后续reuse 9次；其他已预热identity也反复再次present。
- 例如约10.568s，identity `<-564c...>`在page重新进入visible transition后出现`frameUploaded residentReuse=true`，紧接着same frame再次`framePipelineTiming`；其`outputReadyToPresentMicros`累计约8.1s，表明frame早已ready而只是很久以后再次进入presentation。

## 源码因果链
`PipelinePageOutputStream._present()`已有same identity/frame短路：当`snapshot.frameIndex == upload.frameIndex && _identity == identity && !snapshot.replacing`时不会再次present。因此Trace中的same-frame presentation ordinal不断增加，机械上要求中间发生过binding/projection状态变化。

旧`_bind(null)`在UploadDemand消失时立即发布`surface=null`并释放PresentClaim；`LocalImagePlayer`对Pipeline WebP的build逻辑则是`surface == null ? loadingIndicator : surface.build(...)`。也就是说，dev.295正确撤掉hidden speculative upload时，Pipeline却同时把已显示的authoritative static UI surface撤掉；页面稍后成为transition/current/visible时，再通过resident reuse零copy挂回。这是“scheduler eligibility”越权成为“presentation lifetime owner”。

## 排除项
- dev.297 paint snap / bounded rounding只有<=0.5 physical px量级，用户设备反馈明确远大于此，产品行为回滚。
- 当前Trace仍可见current±7 cache edge的pageHost mount/dispose churn，但dev.284曾用mount-travel guard机械消除同类短命host churn而设备抖动仍在，ADR0263已Superseded；不得恢复该guard。
- dev.294–296已经分别冻结actual Sliver extent、hidden speculative static upload copy、sourceCanvas presentation aspect authority；本轮不重开这些owner。

## dev.298候选
`PipelinePageOutputStream`显式记录当前可见surface的`DecodeId`。upload identity变为null时，仅当同一DecodeId仍存在于`currentPlan.decodes`、surface为authoritative static且至少一个listener仍消费时保留surface/claim；重新获得相同upload identity后维持`ready/replacing=false`，让same-frame present短路。离开decode plan、真实dispose、identity/generation变化或无listener时释放。该合同只复用既有decode 1/2窗口，不新增retention策略。

## 下一次设备判据
1. 同一区域反复跨current/transition边界，预热static frame在decode window内不应再周期性出现same-frame `platformResidentReuse=true`再次presentation。
2. hidden speculative static仍应保持`staticWarmUploads=0`，证明没有用恢复upload来掩盖问题。
3. sourceCanvas/scale保持dev.296/dev.293正确状态；dev.297 pixel snap不得存在。
4. 若上述机械闭环后大幅抖动仍存在，下一轮新增Flutter `FrameTiming`、ScrollPosition每帧paint采样与Texture compositor时序关联，优先检查掉帧/帧节奏，不再猜像素级geometry。
