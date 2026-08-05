# zic Implementation Plan

本文件只列未完成工作。

## P0：Flutter 编译闭环

- 在真实 Flutter/Dart SDK 中执行 `flutter analyze`、catalog/downloads/local_media_ui owner tests 和 App target tests。
- 确认 `_browseWeight/_comicWeight/_chapterWeight` 编译闭合，metadata cache stats 使用非占位权重。
- 复验 cold Reader artifact 测试不再出现 `Future.catchError` 返回类型异常。
- 不为旧日志中已被当前 API 取代的方法恢复 compatibility facade。

## P0：Android 运行模式身份设备闭环

- 在同一设备依次运行 debug/profile/release，确认 package、versionName、versionCode 和签名链一致，切换模式不卸载、不清空数据。
- 记录 `dumpsys package dev.zic.zic` 与安装前后数据目录；若仍卸载，优先检查签名或 Flutter tooling。

## P0：封面冷启动与可信缓存身份

- 区分 memory hit、persistent file hit、legacy URL migration 和网络 miss，验证 stable cover key 不因 URL/token 更新重建请求。
- 在 E-Hentai/Venera 来源适配器接入可信旧/新 gallery relation；复用只允许 checksum、image key 或唯一 hash。
- 检查重复/缺失 image key、页序变化、插页和删除页，歧义页面必须保持 miss。

## P1：Reader 与纵向性能回归

- 继续验证同章资源会话 retention、fresh used texture、holder playback、7/3 与 7/5/3/2 合同。
- 使用设备 Timeline 验证稳定 page composition 与渐进 host warm；不得新增 Reader 私有图片缓存或竞争 scheduler。
