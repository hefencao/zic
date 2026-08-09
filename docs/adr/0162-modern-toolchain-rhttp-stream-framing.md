# ADR 0162：稳定工具链现代化与 rhttp Stream Framing

状态：Accepted（第4项工具链版本由 ADR 0163 取代）

## 背景

dev.178 将生产 external source media HTTP engine迁到 Rust/rhttp，但设备 trace 显示一类15–20MiB媒体会把 reqwest接收的约1–16KiB网络 packet逐个作为 Dart Stream event交给 DownloadJob。每个packet都会继续触发 session copy、artifact append、native ingress、状态/trace更新；HTTP engine升级本身因此没有复现 VibeVenera 的整体吞吐形态。权威 VibeVenera源码在rhttp stream之上先聚合首64KiB，之后以256KiB为阈值向pipeline输出。

与此同时，AGP9/Flutter开始迁移Built-in Kotlin。ZIC的五个本地Flutter Android plugin仍自行apply KGP，产生未来Flutter会拒绝的构建警告。项目尚未进入生产环境，可以提升稳定SDK基线并统一普通依赖，但 Mihon extension ABI和隔离runtime编译链中的版本并不都是普通依赖，不能机械升级。

## 决策

1. `downloads_bridge/RhttpSourceResourceDirectTransport` 使用 rhttp 0.18.0；`downloads`仍是调度/重试/artifact owner，bridge不建立第二scheduler/cache。
2. media prefix通过后，底层rhttp packet进入单一 framing buffer：首个逻辑块达到64KiB即发出，之后达到256KiB即发出，EOF刷新尾块。保留底层packet边界，不要求精确切片；字节顺序、Range、validator、TaskControl取消和response abort语义不变。
3. 全workspace最低环境提升为 Dart 3.12 / Flutter 3.44。普通pub依赖升级到该稳定SDK可接受的当前稳定版本。
4. Android稳定基线使用 AGP9.1.1、Gradle9.3.1、compileSdk37、JDK17。项目提交Gradle daemon JVM 17 criteria，不以`--enable-native-access`掩盖高JDK运行Gradle的警告；wrapper client若仍由更高JDK启动，应由开发环境把`JAVA_HOME`对齐JDK17。
5. `local_media_bridge/network_bridge/plugin_host_bridge/runtime_bridge/texture_bridge`不再自行apply Kotlin Gradle Plugin，也不声明自己的KGP classpath；使用`kotlin.compilerOptions` JVM17，为AGP built-in Kotlin准备。稳定Flutter3.44阶段保留`android.builtInKotlin=false`兼容层；Flutter3.47+进入stable并完成设备构建验证后才切true。
6. 普通Maven runtime/test依赖可更新到当前兼容稳定版本；Mihon extensions-lib Git SHA、Injekt ABI、QuickJS SHA、RxJava1和用于构造指定extension ABI的Kotlin compiler/stdlib保持兼容固定，除非有对应ABI升级证据和独立回归。
7. `pubspec.lock`只能由真实Dart/pub解析生成。缺少Flutter/Dart工具链的发行环境不得手工构造rhttp或其它archive hash；应用该版本后必须先运行`flutter pub get`。

## 后果

- 下载仍保持7/3工作窗和5路网络并发，但数千个Rust网络packet被收敛为几十至数百个面向Pipeline的逻辑块，减少主isolate调度/commit固定开销。
- Built-in Kotlin迁移从“未来Flutter构建失败”变成已准备状态，不需要为了消除警告提前使用beta Flutter。
- 工具链版本由稳定兼容矩阵而非“绝对最新preview”决定；插件兼容ABI不会因普通依赖升级被破坏。
