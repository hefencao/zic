# ADR 0191：版本页映射、Reader 快速路径与 partial 复用

状态：Accepted
版本：0.31.0-dev.210

## 问题

dev.207–209 在进入 Reader 前调用版本 artifact reuse preparation。Venera/E-Hentai 的页面 locator 是 opaque `venera-resource:`，因此 preparation 会通过 source request-plan解析强媒体 identity。01:09 真机trace中 Home封面约1.07s完成，而第一次 `version-artifact-alias-prepared` 到约13.96s才出现，Reader随后约14.08s创建；Reader创建后约0.27s首帧，证明长等待属于route前版本解析而非Pipeline。

VibeVenera 的成熟实现把版本发现/page match放在详情页与Reader入口的异步任务，持久化已验证offset；Reader恢复时只读relation/page metadata并注册临时key alias，不现场重新解析网络identity。

## 决策

1. `ComicVersionRelation`可携带`ComicVersionPageMapping`：predecessor/successor chapter ID、两侧page count、`successorOffset`与验证时间。SQLite schema=8，v7迁移增加`page_mappings_json`。
2. 详情页进入和Reader进入都可以异步刷新source versions、加载必要章节metadata、用`verifiedPageReuseIdentity`验证anchor并持久化mapping；这些工作不得阻塞Navigator/Reader创建。
3. Reader前仅允许本地fast restore：从`HomeLibrarySession.versionRelations`和已持久化chapter entry读取mapping，用`VerifiedArtifactReusePlan.fromVerifiedOffset`注册现有promoted artifact alias。没有mapping时直接正常Reader，不等待网络。
4. mapping是双向可消费的：持久事实仍定义predecessor→successor offset；打开successor使用offset，打开predecessor使用反向offset。artifact alias继续保持无环且不复制/迁移library实体。
5. partial可复用，但只允许`PartialDownloadStore`暴露的durable inactive prefix。hot DownloadSession不参与。目标ID没有partial时可复制verified source prefix；ETag/Last-Modified清空，保留totalLength。
6. 真实续传仍由`DownloadJob`唯一决定。validatorless Range probe必须读取服务端重叠区并逐字节比较本地partial，失败则拒绝续传；版本mapping不能绕过该完整性检查。
7. source-card `!`由confirmed relation直接投影：当前卡必须匹配predecessor raw/canonical identity，且不能是该relation的successor。版本relation不得再镜像为chapter `sourceUpdateAt`。

## 结果

冷启动Reader不再承担版本发现/request-plan解析成本；mapping预热成功后后续访问可直接复用full artifact，durable partial也可在不继承跨URL validator的前提下安全复用。首次尚无mapping时性能退化为正常origin路径，而不是阻塞UI等待优化。
