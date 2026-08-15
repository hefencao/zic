# dev.299 direction-stable static presentation / frame cadence 审计

## 触发
用户在dev.298后继续报告明显纵排抖动，并提供`zic-debug-trace-2026-08-15T10-27-22.jsonl`。dev.298的目标是让已显示static surface在UploadDemand暂时退出但同一DecodeId仍处decode plan时保持；本轮首先验证该机械条件，而不是重新猜geometry。

## Trace事实
- 共3411条事件；`pageLayoutSnapshot`458条，继续保持`extentDeltaPx=0`、identity scale/shear与稳定layout residual，Sliver/item extent无大幅跳动证据。
- `framePresented`29次，全部为authoritative static frame0；多个identity仍重复出现same-frame `platformResidentReuse=true`，例如page14对应identity累计9次。后续reuse的blit/schedule/channel为0，因此不是native recopy成本。
- page12–16的host从约2.56s一直mounted到reader teardown，故中央页面重复presentation不是host dispose/remount造成。
- 关键序列：page14已显示；约6.34s current变12且`readDirection=-1`时，directional decode previous1/next2只覆盖12、11、10、13，page14虽然绝对距离2却退出`currentPlan.decodes`。约8.16s page14重新成为visible transition，随后同一resident frame再次presentation。

## 根因收口
dev.298把projection retention绑定“当前directional decode plan”，仍让read direction间接拥有已显示surface生命周期。角色/方向变化可以在页面仍离viewport很近、host持续mounted时清空whole-page projection，稍后再挂回。该视觉量级可以是整页/loading切换，而不是subpixel。

## dev.299候选
保留现有directional decode 2/1 work policy；仅对已经存在的authoritative static surface，把continuity eligibility改成两种directional decode窗口的方向并集`current±2`。它最多比某一时刻的4-page directional decode plan多保留一个既有surface，不创建decode/upload/present。另增加Reader-owned真实Flutter `readerFrameTiming`，记录build/raster/total span、vsync interval与scroll context，为下一轮直接判断整帧掉帧/cadence。

## 下一次设备判据
1. 已显示static page在绝对距离<=2内因方向翻转暂时离开directional decode plan时，不得再出现surface blank或same-frame resident re-present。
2. `staticWarmUploads=0`与decode previous1/next2必须不变，证明没有用恢复后台work掩盖问题。
3. 若大幅抖动仍存在，检查`readerFrameTiming.frameIntervalMicros/buildMicros/rasterMicros/totalSpanMicros`与scroll位置跳变；优先处理UI/raster/compositor frame cadence，不再增加presentation retention半径。
