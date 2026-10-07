# ADR 0255：Reader generation ingress 与 uploader retirement 闭合

状态：Accepted

## 背景

07:54 dev.276 真机 Trace 同时暴露两类“已经有字节/已经解码，但页面仍打不开”的问题。

1. 网络 page216 已发布约5.58MiB Reader-local WebP prefix，随后 synchronized late-join attachment 失败；旧实现把该 attachment failure 直接投影为整个 ingress failure，使 decode 后续只看到不可用 source。
2. 本地 page0 第一次进入 Reader 正常首帧约454ms；退出后第二次进入，同 DownloadId 切换到新 physical DownloadSession generation，source重新增长到完整5.9MiB且 decode depth 到7，但多次 `uploadStarted` 后始终没有 `frameUploaded`。旧 UploadSession 在 generation invalidation 时若仍有异步 prepare，会把 `uploader.release(DecodeId)` 延迟到旧 prepare 结束；新 generation 已可用同一 logical DecodeId 建立 UploadSession，因此旧 async tail 可能反向释放新 generation 的 uploader slot。

同时源码审计发现 `DownloadIngressProjectionRegistry.attach(session)` 已按 DownloadSession 对象 identity 区分 physical generation，但公开 `get(session)` 只按 DownloadId 命中旧 entry；这与 ADR0232/现有 same-id generation 回归合同冲突。Artifact promotion 也存在 owner 内部 rename 窗口：data file 已从 partialPath rename 到 finalPath，而内存 state 尚未从 sealed 切到 promoted，Reader replay若只按 state 选路径会误读为空。

## 决策

1. `DownloadIngressProjectionRegistry.get(session)` 必须统一经过 generation-aware `attach(session)`；same DownloadId + different DownloadSession object 必须退休旧 Reader-local projection/source并创建新 generation projection。
2. `Artifact` 自己隐藏 partial→final promotion 的文件名切换。Reader readBytes/readChunks/readPrefix 必须通过 Artifact 打开的 authoritative file handle 读取：按当前 state 尝试 preferred path，open失败只允许 fallback 到同一 Artifact owner 的 alternate partial/final path；不得把 rename 窗口投影为0字节。
3. `DownloadSession.attachSynchronizedIngressProjection` 只有在 physical boundary 未变化且 projection snapshot 的 epoch/length/sealed/failure 精确匹配该 boundary 后才可加入 live fan-out。physical变化可重放；physical稳定但 projection 未追平属于 source failure，不能把 incomplete projection 宣称 attached。
4. `UploadSession.dispose()` 是 generation retirement barrier。即使旧 generation 仍有 pending prepare，也必须立即 `uploader.release(id)` 并清除 deferred-release flag；pending async tail unwind 后不得再次 release 同一 logical DecodeId。普通 `detach/reset/frame-budget` 仍可沿既有 pending-prepare deferred release，避免把普通 demand churn误当 generation replacement。
5. LiveCoordinator 继续是 physical-generation rebind 的唯一识别 owner；不新增 widget key、Reader generation cache、upload retry 或第二 uploader registry。

## 被拒绝方案

- 网络/partial 图片打不开时自动 redownload/retry：会掩盖 Reader projection attachment 与 Artifact promotion race。
- 本地第二次进入时强制重建 Reader/widget 或清 texture cache：decode 已正常到depth=7，问题是旧 generation async tail跨代释放新 uploader slot。
- 给 FrameUploader 再加一套 Reader generation map：UploadSession dispose 已是明确 generation retirement barrier，新增 map 会形成第二 lifecycle owner。
- promotion 期间在 Reader 侧猜 partial/final path：path transition属于 Artifact owner，Reader/sessions不得知道文件 rename 时序。

## 验证不变量

- same DownloadId 的新 DownloadSession object 通过 registry `get()` 必须得到新的 projection/native source generation。
- sealed→promoted rename 窗口内，Artifact三种读取接口都必须读取同一authoritative encoded bytes，不得返回人工0字节。
- synchronized projection加入live fan-out时，其epoch/length/sealed必须与已验证physical boundary一致且failure为空。
- old UploadSession dispose 后 uploader slot立即退休；旧 pending prepare完成后不得发生第二次 delayed release。
- ordinary detach pending-upload仍保持原有 deferred release语义。
- previous3/next7、5/3/2/1、decode2/1、holder7/5/3/2、NetLane normal5+current reserved1、Venera single-invocation均不变。
