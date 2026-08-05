# dev.135 验证结果

## 已完成

- repository/documentation/Dart structure/directive order/Pipeline compile boundary。
- dev.75–dev.135 历史所有权门禁；dev.116 门禁更新为同时约束 exact key 与 alias-resolved storage 的必需 backend invalidation。
- Android texture Kotlin stub 编译。
- Android runtime dependency、Trace export、Mihon entry/context/ABI/classloader/read-only/chapter、Venera network/native/header/preflight/bootstrap、source resource binding、Reader/Pipeline/UI、外部登录和设置合同。
- Venera Node bootstrap 验证：同一 raw comic/ep 在标题、封面、简介、章节标题、sequence 改变后仍保持 comicId/chapterId；旧 opaque payload 可读取。
- dev.135 专项门禁验证：Android 三种模式版本身份、稳定封面 key、单一缓存 owner、artifact alias/rekey、existing-only 复用与 E-Hentai image-key 匹配。
- 锁定 `libwebp-1.6.0.zip` 的全新 shared host build，以及 incremental/loop Animated WebP smoke。
- Python compileall 与 shell syntax。

`tool/check.sh` 因单次执行窗口分段运行；每次中断都从下一项继续，没有把超时本身记作通过。

## 实现级结论

- debug/profile/release 的 Android applicationId/versionName/versionCode 来自同一项目版本文件，且没有 build-type suffix。
- 封面响应继续由唯一 `ResourceCacheCoordinator.responses` 管理；Reader 页面 artifact 继续由唯一 composition-owned `ArtifactCacheManager` 管理。
- 封面 URL/token 不再参与稳定 cover key 或首页 Future identity；legacy URL key 仅单向读取迁移。
- Venera 新实体 ID 不再包含可变展示字段。
- 用户确认的漫画源迁移会根据 checksum、E-Hentai image key 或唯一 hash 构建页面映射，并且只为实际存在的旧 artifact 注册 alias。
- 同源 E-Hentai predecessor/successor 自动发现尚未实现；没有以标题、作者或页码猜测关系。

## 未验证

当前环境缺少 Flutter/Dart SDK、Android Gradle/SDK/NDK、Cargo/rustc 和 ADB，因此未执行或未声称：

- `flutter analyze`、Dart/Flutter owner tests；
- debug/profile/release APK 构建和同设备模式切换；
- 冷启动封面真实耗时及 durable file hit；
- 真实 E-Hentai 新旧版本自动关系发现与设备缓存复用；
- Android release 安装、签名和应用数据保留。
