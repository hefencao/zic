# dev.282 retained texture presentation audit

## 真机事实
14:02 dev.281 Trace中slow-release路径已经没有idle后反向current/logicalPosition跳变；active vertical policy的`staticWarmUploads=0`也证明dev.281 next2 deferral在设备上生效。剩余ballistic抖动仍包含多次15–37ms platform presentation，并且部分样本的presentation ordinal已是1、2、3，uploadStartedAt远早于当前role切换。

## 根因审计
源码显示Android `_AndroidTextureFrameUploader.upload()`并不执行RGBA Surface copy；它只保留NativeFrame并取得`AndroidTextureLease`。真正copy路径是 `_AndroidTextureOutputFrame.present()` → `AndroidTextureLease.present()` → MethodChannel `present` → Kotlin `Output.present()` → `NativeBlitter.blit()` → `scheduleFrame()`。UploadSession会为authoritative static保留OutputFrame，因此同一对象再次进入presentation window时旧实现仍重复整张copy。

这说明dev.281“active时defer hidden next2 UploadDemand”只阻止新的隐藏output准备/投影，不能删除已经retained output在role rebind时的重复presentation copy。继续缩window或改anchor无法解决该重复owner工作。

## dev.282收口
texture lease新增resident OutputFrame identity与presentation revision。same-object重复present为零copy resident reuse；不同对象/resize/release失效。revision保证older async completion不能把resident identity写回旧值。Kotlin现有SurfaceProducer callback仍负责surface重建后的redraw，未新增第二套surface owner。

## 下一份Trace判据
1. dev.281 slow-release不得回归。
2. retained static再次投影时应出现`presentationPath=platform` + `platformResidentReuse=true`；该次platform blit/schedule/channel round-trip应为0。
3. 首次新frame仍是`platform`，其耗时单独统计。
4. 若2闭合而fast ballistic仍抖，下钻首次visible/current presentation、Flutter frame/raster/compositor与SurfaceProducer buffer contention；不再修改geometry/anchor或缩preload window。
