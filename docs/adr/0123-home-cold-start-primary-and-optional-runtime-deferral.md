# ADR 0123：首页冷启动主投影与可选运行时延后

**状态：Accepted**

## 背景

首页封面首帧依赖的只是本地库主投影、封面响应缓存和 Flutter 图片解码，
但旧冷启动路径还在此之前等待 native media 预热、整本下载队列恢复和已安装
外部插件激活。主投影发布后，Home session 还会继续在同一 isolate 执行目录
增强和缺失偏好补写，容易让已安排的 Flutter 首帧继续排队。外部来源延后可用
时，已经失败的封面 loader 也不会自动重试。

## 决策

1. `main()` 直接呈现 App 的 memory-backed Home，不创建自定义 Flutter bootstrap
   surface；durable services、外部插件和 native capability 均不得成为首页首帧的硬门槛。
2. `WholeComicDownloadQueue` 的持久 JSON restore 通过 `ready` 表达，App 只创建
   queue，不在首页组合完成前等待 restore；需要队列状态的 Home/Download Manager
   继续显式等待 `ready`。
3. `ExternalPluginController.openDeferred()` 只完成 manifest 准备并立即返回；
   设备扩展发现和已安装插件激活由 `ready` 完成。`open()` 保留原有 eager contract，
   继续等待 `ready`。
4. Home 先发布 entries/SavedComic primary，等待一个可注入的 primary frame 边界，
   再执行 enrichment。外部来源 ready 后只替换 source projection，不重新读取整库。
5. `_CoverImage` 只在 cache identity 改变，或 source 加载失败且来源从不可用变为可用时重试；
   稳定 identity 的成功缓存不会因普通 Widget rebuild 重复请求。

## 后果

- native 预热、队列 restore、插件激活和偏好补写不再成为首页首封面请求的硬门槛。
- 已安装外部来源会在后台激活完成后加入 source projection；激活失败仍通过
  `activationFailures` 保留，不影响内置来源首页。
- `HomeLibrarySession.ready` 表示 primary 与后续 enrichment 完成；队列恢复由 session
  独立观察并只发布下载投影，不再成为该 ready 的等待条件。
- 该决策只解决可归因的 App 冷启动排队，不改变远程封面服务器响应时间或统一
  response/artifact cache 所有权。

## 验证边界

源码、owner tests 与工具链已验。SWG-PLAN-109 复用当前普通 Release 的新进程与
新 Flutter engine 启动记录：首页先显示，首批封面请求先于 durable services，封面帧
先于章节下载/队列与外部插件就绪。该设备使用已有 durable covers；快慢混合、来源失败、
alias 与最终物理显示验收仍由各自开放项承担，不从本启动时序推断。
