# ADR 0261：Retained Android texture resident presentation

## 状态
接受，dev.282。

## 问题
14:02 dev.281 真机Trace已经排除slow-release geometry回跳，并确认active vertical时hidden next2 UploadDemand确实被defer；但fast fling仍有15–37ms presentation。源码与Trace对齐后发现，`FrameUploader.upload()`只创建/复用texture lease并持有NativeFrame，真正RGBA→SurfaceProducer copy发生在`OutputFrame.present()`。静态OutputFrame可由UploadSession保留；当它从next2/previous重新成为next/visible时，现有代码会对同一lease和同一frame再次执行native retain、`ANativeWindow` blit与schedule，即使SurfaceProducer里已经是这张图。

## 决策
`AndroidTextureLease`是单个SurfaceProducer resident内容的唯一Dart侧owner。它记录最后一次成功platform present的**具体OutputFrame对象identity**：
- 同一identity再次present时不跨MethodChannel，不retain native frame、不blit、不schedule，返回`residentReuse=true` telemetry；Pipeline把它投影为`platformResidentReuse=true`。
- 不同OutputFrame present前推进本地presentation revision并清空resident key；只有仍是最新revision的成功async结果可以登记新resident，防止older async tail覆盖新owner。
- resize/release推进revision并清resident identity。
- SurfaceProducer cleanup/recreate不由Dart自行猜测。Kotlin Output已retain `currentFrameAddress`，`onSurfaceAvailable`继续调用既有`redraw()`重新blit并schedule，因此Dart resident identity在platform redraw后仍代表同一内容。

## 非目标
- 不把首次新OutputFrame的Surface copy改成零copy；首次presentation成本仍需真机单独测量。
- 不修改Reader geometry/anchor、Pipeline window、decode水位、NetLane、Venera或缓存容量。
- 不让Reader或Pipeline拥有SurfaceProducer生命周期。
