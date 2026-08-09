# dev.179 审计：工具链升级与 rhttp Stream Framing

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.178_vibevenera-rhttp-startup-transport.zip`
- 设备 trace：`zic-debug-trace-2026-08-09T02-48-10.jsonl`
- 只读参考：文件库权威 `vibevenera-master.zip`
- 用户本地构建反馈：rhttp 0.13编译失败；改0.18.0和compileSdk37后出现Gradle native-access及本地Flutter plugin KGP迁移warning。

## Trace结论

结构化扫描3110条事件；其中25条origin source read的`openMicros`中位约6.20s、p90约8.11s、最大约8.43s。rhttp已进入生产路径，但小packet forwarding明显：例如15,640,724字节响应产生10,713个chunk，chunk约1,204–1,460字节；20,133,362字节样本产生13,790个chunk。`firstChunkMicros`本身只有毫秒级，因此瓶颈不是rhttp没有stream，而是每个底层packet都被放大成上层Dart event/commit。

权威VibeVenera源码对rhttp流使用两级聚合：首个逻辑stream chunk以64KiB为阈值，后续以256KiB为阈值，EOF刷新剩余字节。该行为不改变下载工作窗或lane并发，因此应作为transport framing迁移，而不是修改7/3或current preemption。

## 工具链结论

- rhttp 0.18.0是当前稳定版本并要求Dart>=3.9；提升到Dart>=3.12可覆盖当前直接pub依赖。
- Flutter Built-in Kotlin官方迁移要求plugin作者在最低Flutter>=3.44时移除plugin自身KGP application与legacy `kotlinOptions`，改用`kotlin.compilerOptions`；真正启用`android.builtInKotlin=true`要求Flutter>=3.47，因此当前稳定3.44阶段只完成plugin源码迁移，不切beta工具链。
- AGP9.1稳定支持API37，并与Gradle9.3.1/JDK17配套；继续使用9.1.1，不追9.4 preview。
- Gradle `System::load` restricted warning不通过添加全局native-access参数掩盖。项目提交daemon JDK17 criteria；若wrapper client仍由高版本JDK启动，开发环境应同步JAVA_HOME到17。

## 依赖升级边界

已升级普通直接依赖：rhttp0.18.0、flutter_lints6、file_selector1.1、ffi2.2、crypto3.0.7、sqlite3 3.5、path_provider2.1.6、test1.31.2；Android host更新Gson2.14、kotlinx serialization/coroutines1.11、org.json测试依赖20260522，并使用Kotlin runtime2.4.10。

没有机械升级Mihon extensions-lib Git SHA、Injekt、QuickJS、RxJava1以及兼容runtime生成使用的compiler/stdlib。这些版本定义extension ABI/isolated asset，而不是可独立升级的普通应用库。

## 未验证边界

当前执行环境没有Flutter/Dart，因此不能运行`flutter pub get`、analyzer、Dart/Flutter tests或Android Flutter build，也不能由pub重算`pubspec.lock`。不得手工伪造lock；用户本地首次验证必须先运行`flutter pub get`。
