# ADR 0277：静态 Presentation 生命周期独立于 UploadDemand

## 状态
Accepted，设备效果待dev.298真机证伪。该决策只修正Reader-local presentation projection所有权，不扩大任何资源窗口。

## 设备证据
10:01 dev.297 Trace中实际纵排page layout继续稳定，但同一authoritative static frame 0在首次platform present之后，随着角色重新进入upload demand反复出现`platformResidentReuse=true`的再次presentation。代表identity `<-564c34595f9ca003,254>`共present 10次，其中后9次均为resident reuse；`<-7ced3512dc3d6999,254>`同样共10次。重复presentation的platform blit/schedule为0，说明physical texture本身仍驻留。

`PipelinePageOutputStream._present()`对同一identity/frame且`snapshot.replacing=false`本来会直接返回，因此这些same-frame再次presentation意味着中间发生过output projection rebind。旧`_bind(null)`把`surface`发布为null并释放PresentClaim；`LocalImagePlayer`在`surface == null`时直接显示loading indicator。故UploadDemand的暂时撤销不仅停止调度，还错误地销毁了已经显示的静态UI projection；后续重新进入current/transition/visible时再把同一resident texture挂回。该行为的视觉量级可远大于subpixel seam。

## 决策
1. UploadDemand membership只拥有presentation claim/retention identity，不拥有已成功静态Presentation的可见生命周期；ADR 0330进一步把新的upload/present执行资格显式收口到`prepareOutput=true`。
2. 当upload identity暂时为null时，只有同时满足以下条件才保留既有surface/PresentClaim：页面仍有presentation listener；surface已是authoritative static；`surfaceIdentity`与当前Pipeline plan中该DownloadId对应的同一`DecodeId`一致。
3. retention严格绑定既有decode previous1/next2 window；它不得创建DecodeDemand/UploadDemand、不得扩大3/7或2/1、不得主动调用present，也不得形成独立page-distance/role窗口。
4. 相同upload identity恢复时，如果surface仍是同一authoritative static projection，保持`ready/replacing=false`，随后same-frame `_present()`应直接短路，不再产生resident re-present。
5. DecodeId离开decode plan、generation/target改变、UploadState真正disposed、output dispose，或upload已解绑且最后一个listener移除时，必须释放projection与PresentClaim。animated output不得跨upload-demand gap使用本合同保留。
6. dev.297的physical-pixel snap、external-texture marker与`<=0.5px` bounded fill回滚；dev.293 aspect-preserving fit和dev.296 physical sourceCanvas presentation authority保留。dev.284 mount-travel keepAlive guard仍禁止恢复。

## 可证伪条件
下一份设备Trace在同一区域复现时，已预热static page在仍处decode window的current/transition/visible角色往返期间不应再因upload-demand gap产生同frame resident re-present；UI也不应在该gap发布null surface/loading。若该机械现象消失而大幅抖动仍在，冻结本路线并增加真实Flutter `FrameTiming` / UI frame cadence与external Texture compositor时序观测，不再叠加geometry、pixel snap、keepAlive或资源窗口补偿。
