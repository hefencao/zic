# dev.206 所有权根因审计：partial 与 Venera HTTP

## 结论

用户指出 dev.205 虽修到现象，但架构边界较 VibeVenera 混乱。源码复审确认两处 ownership drift。

### partial

`PipelineReaderSession` 已有两分钟 retention pool，同 chapter route reentry会直接复用整个 session。因此 dev.205 在 `retainReaderSession()` 再做 durable checkpoint 是重复状态迁移，并错误把普通 UI route lifecycle 变成 persistence boundary。更严重的是 `ArtifactCacheManager` 靠 optional partial capability访问 mutable incomplete artifact，最终直接造成 Dart 编译错误：manager的静态 backend 类型没有 partial方法。

dev.206 改为 hot/cold 两层但单一职责：hot partial原位留在 DownloadSession；只有 session 真正销毁才冷交接给 `PersistentChapterDownloadService`。promoted cache继续独立。30帧循环没有从 VibeVenera照搬；它是 ZIC 后续能力，只留在 DecodeSession。

### Venera HTTP

旧路径是 `Network.* -> Kotlin HttpURLConnection/DoH/reflective OkHttp`，而最终媒体是 rhttp。dev.204仅改善前者成功连接的复用，未解决两个client family。dev.206将normalized single HTTP request交给 isolated Dart rhttp service；Cookie、cache、redirect和JS contract仍由Venera runtime层控制。旧DNS/reflective client与requestConnections tracking随 owner迁移删除，避免“新 owner已上线、旧 owner仍留作 fallback”的双栈。

## 不修改

Reader 7/3、decode 2/1、holder 7/5/3/2、network/decode/upload 5/3/2、current 1000、transition 900、next 820、previous 780、current handoff 1、preemption threshold 40、dev.204 retention插值、DownloadJob 16/64KiB framing、Range/continuity/admission均不修改。
