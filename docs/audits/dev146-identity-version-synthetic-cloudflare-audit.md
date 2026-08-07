# dev.146 身份、版本、伪章节与 Cloudflare 审计

## 发现

- Preview/Comment capability 曾依赖编译器跨闭包提升。
- 远程详情虽过滤 synthetic，SavedComic 仍可能持久化“开始阅读/正文”。
- WebView 正常不等于 isolated Mihon CookieJar 已导入当前 snapshot；host/subdomain revision 可能不同。
- 旧 UI 同时存在新版、旧版、迁移按钮，且 predecessor 被错误呈现为可迁移目标。

## 修复

- 显式 cast capability。
- 保存目录前构建去 synthetic manifest并清理旧 imported entry。
- runtime restart 清空本进程 import revision，真实请求按 same-site snapshot导入。
- 双向 version relation、详情 successor banner、Reader one-time notice；删除旧 UI。
- Architecture 写明 key/id 层次和 migration 规则。
