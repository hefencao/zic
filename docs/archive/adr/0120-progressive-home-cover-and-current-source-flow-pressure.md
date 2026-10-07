# ADR 0120：首页主投影提前发布与 Transport 小块合并

**状态：Accepted**

## 背景

首页服务可很早 ready，但旧初始化必须等待分类、偏好、源偏好、阅读状态和默认值补写后才发布漫画卡片，导致封面请求明显晚于缓存和图片解码本身。

部分远程来源还会把十几 MiB 页面拆成大量约 KiB 级 transport chunk；若每个 chunk 都直接触发 artifact、native ingress、source revision 和进度投影，会放大调度开销。

## 决策

1. `HomeLibrarySession` 将可产生封面的 primary projection 与 enrichment 分离。章节列表和 SavedComic 并行读取并立即发布；分类、偏好、源偏好、阅读状态和缺失默认值补写在后续阶段完成。
2. `DownloadJob` 合并普通 response 的任意 transport chunk：首批约 16 KiB，之后按 64 KiB source-progress quantum 提交；partial/resume 和错误前已收到字节保持。
3. 首页 Trace 可记录 primary/enrichment 与 first cover request 时间；DownloadSession/Trace 不应把 transport 的任意小块边界放大成同数量的持久写入和 source wake。
4. 网络优先级仍只属于 NetLane。本 ADR 不定义 holder-depth、播放状态或同 source bucket 的网络资格门控。

## 所有权

- 首页 primary/enrichment：App 的 HomeLibrary session/controller。
- response chunk 合并和 partial 提交：`sessions/DownloadJob`/`DownloadSession`。
- 网络排名、保留槽和抢占：composition-owned `NetLane`。
- Reader 不参与首页缓存或 transport 调度。

## 取代关系

本 ADR 早期实现曾加入 `DownloadFlowGate`。该路径已由 ADR 0121 删除，不属于本 ADR 的当前决策。首页分阶段发布和 transport 小块合并继续有效。

## 边界

- 不改变 encoded +7/-3、holder 7/5/3/2、lane 5/3/2 或 remote bucket 5。
- 不改变 native ABI、texture、decode worker 数量或 WebP duration。
