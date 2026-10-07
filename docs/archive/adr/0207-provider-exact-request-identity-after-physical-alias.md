# ADR 0207：physical transfer anchor 与 provider exact request identity 正交

- 状态：Accepted
- 日期：2026-08-11
- 版本：0.31.0-dev.227

## 背景

dev.225 Phase C1允许direct verified equivalent exact demand在physical acquire之前加入已有transfer。设计上claim一直保留自己的exact `DownloadId`，而physical `DownloadSession.id`只作为首个physical artifact/hot-partial anchor。

15:29真机Trace证明alias真实命中13次，但同时出现43次`Failure(source): unsupported URI scheme: venera-resource`。其中6次alias加入的是已有committed prefix的`failed` physical session。审查发现owner虽然以claim exact URI选择consumer transport，`DownloadJob`内部的full/range/resume open仍硬编码`session.id.canonicalUri`。当physical anchor来自旧版本A、当前provider来自新版本B时，B transport被要求打开A URI；B Reader/source gateway并不拥有A runtime request identity，因此错误落入IoTransport。

## 决策

1. `DownloadSession.id`继续是physical artifact/writer/resume anchor，不因consumer变化而改写。
2. `DownloadJob`新增显式`requestUri`；未提供时仅为legacy exact-session调用兼容地回退`session.id.canonicalUri`。
3. `DownloadTransferOwner`每次physical attempt从preferred claim取得exact `DownloadId`，同时用其URI选择transport并作为`DownloadJob.requestUri`。
4. `DownloadJob`所有full open、Range probe、strong-validator resume和validatorless resume都只使用`requestUri`；不得重新读取physical anchor URI决定source request。
5. session validators/committed prefix仍是physical continuity proof。等价provider不能伪造validator一致性；现有resume rejection/full-body prefix proof继续决定是否安全续接。
6. `failed`且有committed physical prefix仍可作为可恢复alias target；本轮不以状态黑名单掩盖request-identity错误。若后续证据证明某类terminal failure不可重激活，应按failure authority单独建模。
7. Phase E最终late takeover删除暂停到dev.227真机验证完成。

## 后果

- verified physical alias可以共享旧版本hot partial，而source request始终由当前consumer exact authority执行。
- Reader/decode/cache/offline exact identity不被physical anchor污染。
- 旧版本runtime URI不会再泄漏到新Reader的Loader/Source gateway。
- physical continuity proof和source request authority成为两个明确独立的概念。
