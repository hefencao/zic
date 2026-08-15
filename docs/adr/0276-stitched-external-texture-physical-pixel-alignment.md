# ADR 0276：Stitched external Texture 的物理像素对齐

## 状态
Superseded by dev.298。10:01设备复测确认肉眼抖动明显大于1-2px，dev.297的`<=0.5 physical px` rounding / paint-time pixel snap量级不足以解释主问题，因此产品行为回滚；本ADR仅保留为已证伪实验记录。dev.296 physical sourceCanvas aspect authority不回滚。

## 设备证据
09:30 dev.296 Trace继续否证上层owner：8/8尺寸来自physical sourceCanvas；418条实际page layout均extent delta为0、scale/shear identity且residual恒定；92条active vertical policy全部`staticWarmUploads=0`；24次platform timing中19次为zero-copy resident reuse。与此同时，418个sampled page box的物理宽高全部是整数像素，但414个global top不是整数物理像素，fractional phase约分布在-0.49..+0.49px。

ReaderVerticalGeometry按source aspect把item extent舍入到最近physical pixel，因此presentation使用完全精确source aspect时仍可能留下小于半个physical pixel的尾缘残差：本Trace可见page13约0.375px、page14/15约0.25px。该残差远小于已解决的scale defect，却与独立external Texture layer在fractional scroll transform下的边缘采样处于同一量级。

## 决策
1. dev.293的无界`fitWidth -> parent fill`继续禁止。只有parent height与source-aspect fitWidth height的差异`<=0.5 physical px`时，`MediaAspectViewport`才允许吸收Reader同源的nearest-physical-pixel rounding residual；超过阈值必须继续`FittedBox(fitWidth)`。
2. `PipelinePageSurface`新增无状态marker `PipelineExternalTextureSurface`；仅Android external texture实现该marker，不暴露texture id或lease。
3. `LocalImagePlayer`只在`fitWidth + PipelineExternalTextureSurface`时使用`PhysicalPixelAlignedPresentation`。render object只在自身physical width/height均为整数像素且2x2 scale/shear为identity时，在paint阶段把global Y edge snap到最近physical pixel。
4. snap不写回layout：不得改变ScrollPosition、ScrollPhysics、item extent、hit/navigation事实、Pipeline observation或scheduler。普通Flutter image/non-fitWidth/zoom transform路径不进入该修正。
5. encoded previous3/next7、decode previous1/next2、NetLane normal5+current reserved1、texture resident reuse与retention全部冻结。

## 可证伪条件
若dev.297真机同一固定边界仍抖，先确认bounded rounding与pixel snap代码真实生效；随后冻结本路线，直接检查Flutter engine/external Texture layer与SurfaceProducer sampling/crop/clip，不再通过ScrollPosition量化、扩大visual compensation或重开Sliver/sourceCanvas/download路线。
