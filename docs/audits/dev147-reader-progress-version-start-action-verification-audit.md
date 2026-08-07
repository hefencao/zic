# dev.147 Reader progress、版本、开始阅读与验证审计

## 唯一基线

`zic_v0.31.0-dev.146_identity-version-notice-cloudflare-synthetic.zip`

## 发现

1. `MihonRuntimeDriver.kt` 使用 `AndroidBrowserCookieSession` 但缺少 `dev.zic.network` import。
2. Reader page-change progress Future 可并行完成；route pop 不等待，详情页返回后不重载，因此历史常在退出详情后才更新。
3. dev.146 的 App cleanup 无法区分来源合法的独立开始阅读动作与 synthetic gallery fallback。
4. 详情只显示单 successor 提示，缺少 VibeVenera 的查看新/旧版本、多个版本选择和查看/迁移分离。
5. Mihon compatibility Cloudflare interceptor仍创建隐藏 WebView并抛普通 IOException，与 typed主路径分类不一致。

## 修改

- 补 Kotlin import；Reader 写入改为串行合并、正常退出等待、详情返回重载。
- 删除 App synthetic cleanup 和对应 UI tests；在 Mihon adapter 目录边界去重独立动作。
- 读取文件库 `vibevenera-master.zip` 的版本 UI，迁移查看/迁移双动作与多版本 chooser；查看使用临时 route key，持久 raw identity不变。
- 兼容 interceptor 改为 typed detector 薄委托；异常消息不参与验证判断。

## 拒绝方案

- 不按 chapter ID/token/title 在 App 数据库扫除旧记录。
- 不把多个 raw version 合并为一个阅读历史 key。
- 不在查看版本时自动迁移或修改关系。
- 不将普通 HTTP 403、timeout 或包含 Cloudflare 字样的异常映射为验证错误。