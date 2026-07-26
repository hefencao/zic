# zic

`zic` 是从零开发的高性能漫画阅读器。当前版本完成静态 Reader vertical slice，并建立可恢复的编码字节下载基础。

```text
ReaderView
  -> ReaderObs
  -> HeuristicPolicy
  -> DemandPlan
  -> SessionCoordinator

Transport
  -> DownloadJob
  -> DownloadSession + WriterLease
  -> Artifact(partial/meta)
  -> seal/checksum/promote
```

## 当前实现

- Flutter Reader：LTR、RTL、vertical、连续 viewport observation。
- 资源策略：角色窗口、启发式 demand、guard、diff。
- 下载基础：HTTP/File transport、range resume、validator 校验。
- 字节权威：独占 writer、连续 offset、epoch、durable partial。
- Artifact：CRC32、seal、同文件系统 promote、元数据原子更新。
- 测试设施：fake clock、确定性 scheduler、FakeTransport、100 页样例。
- Rust 媒体核心：稳定 ABI/version smoke surface。

内部 package 使用短且无项目重复前缀的名称：`domain`、`pipeline`、`sessions`、`transport`、`storage` 等。`zic_*` 仅保留给需要全局命名空间的 C ABI 符号。

## 检查与运行

```bash
./tool/check.sh
./tool/bootstrap_platforms.sh
flutter run -d android --project-dir apps/app
```

完整架构、规格、计划与实施状态位于 `docs/`。
