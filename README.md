# zic

`zic` 是从零开发的高性能漫画阅读器。当前版本已完成静态 Reader
vertical slice、可恢复字节下载、持久化 cache index、启动扫描恢复和真实 network lane。

```text
ReaderView
  -> ReaderObs
  -> HeuristicPolicy
  -> DemandPlan
  -> Coordinator
       -> NetLane
       -> DownloadRegistry
       -> DownloadJob
       -> DownloadSession

Transport
  -> RunLease / WriterLease / SourceEpoch
  -> Artifact(partial + metadata)
  -> seal / checksum / staged promote
  -> CacheIndex / CacheScanner
```

## 当前实现

- Flutter Reader：LTR、RTL、vertical、连续 viewport observation。
- 资源策略：角色窗口、启发式 demand、guard、diff。
- 下载：HTTP/File/Io transport、range resume、validator 校验和取消响应清理。
- 字节权威：独占 run/writer、连续 offset、epoch、durable partial。
- Artifact：CRC32、seal、final metadata、可恢复 promote。
- Cache：memory/SQLite index、稳定布局、启动扫描、orphan 清理和 active-path 保护。
- 调度：有限并发 `NetLane`、优先级、同优先级 FIFO、coalescing 和 cancellation token。
- 测试设施：fake clock、确定性 scheduler、FakeTransport、100 页样例。
- Rust 媒体核心：稳定 ABI/version smoke surface。

内部 package 使用短且不重复项目上下文的名称：`domain`、`catalog`、`pipeline`、
`sessions`、`transport`、`storage` 等。`zic_*` 只保留给需要全局命名空间的 C ABI。

## 检查与运行

```bash
./tool/check.sh
./tool/bootstrap_platforms.sh
flutter run -d android --project-dir apps/app
```

完整架构、规格、计划与实施状态位于 `docs/`。
