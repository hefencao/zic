# 2026-09-23 Reader 设置 / Mihon recovery / DNS 外部审查复核

## 范围

复核外部审查中列出的 7 项问题，并以当前 `main`/工作区实际代码、既有 ADR/SPEC ownership 与 focused gate 为准，不把旧工作区快照或与现有 retry owner 冲突的建议直接落地。

## 结论

1. **来源设置 contract 与 ADR 0318 半收口：已过时。**
   当前 `sourceSettingsEntryKey`、`sourcePropertiesEntryKey` 与 `source_settings_screen.dart` 已进入 production/tracked tree；
   `test_external_source_settings_contract.py` 与 `test_reader_layout_settings_contract.py` 均通过。
2. **Mihon `Call`“永久泄漏”结论过重，但局部 cleanup gap 成立并已加固。**
   operation 外层 `FutureTask.done()` 原本就会无条件执行 `calls.remove(requestId)`，所以 `execute()` 异常不会形成永久 map 泄漏；
   但 `loadResource` 的局部 response-finally 的确未覆盖 `execute()`。现在把 `execute()` 纳入同一 try/finally，
   当场移除 `calls[requestId]`，response 仅在成功创建后关闭；外层 done 继续作为生命周期兜底。
3. **网络异常一律发布 runtime replay eligibility：拒绝。**
   当前 ADR/SPEC 明确要求 runtime-owned SSL/EOF 继续由 DownloadJob/provider RetryPolicy 处理；
   若同时重读 chapter/page list，会把一个网络失败扩成第二 retry owner。
4. **plugin trust source migration 的 API 边界风险成立并已修复。**
   调用点虽然会合并当前 source、installed record 的 `sourceIds`、静态 descriptor 与 Venera sourceKey，
   但原 migration helper 无条件删除 plugin fallback，无法表达“当前只知道部分 source”。现在 helper 默认只展开 source override；
   只有调用方能从 durable installed record 证明 source 集完整时才传 `retirePluginOverride=true`。
   runtime discovery 尚未完整时旧 plugin fallback 会保留，未发现 source 仍继承历史设置；新增回归覆盖 partial migration。
5. **普通 Mihon page locator 缺 replay 坐标：成立并修复。**
   新 locator 一律携带 chapter/page 坐标；host-direct plan 额外带 `directPlanReplay`。
   这样过期 direct URL 可消费现有 `SourceResourceTransport.retryResource` 一次性 page-list refresh，
   而 runtime-transform SSL/EOF 仍不获得 replay eligibility。升级前已经持久化、仍缺 replay 坐标的
   `mihon:resource:` locator 由 plugin-host bridge 的纯解析 helper 判为 legacy，Home 复用旧 page list 前沿既有
   source-locator refresh 边界强制刷新；不通过修改 `sourceRevision` 制造版本/缓存 identity churn。
6. **FallbackDns 强制 IPv4、public fallback 缺 AAAA：成立并修复；“系统 DNS 必须 public-only 过滤”不采纳。**
   两份 FallbackDns 都保留非空系统解析的原顺序；只有系统失败/空时进入 public fallback，
   UDP/DoH 都查询 A+AAAA 并交错返回。系统答案不做 public-only 过滤，以保留 split-DNS/private host 合法语义。
7. **禁止 `dart format`：本轮遵守。**
   所有修改均为最小手工 patch，没有运行 `dart format`。

## Reader 设置补充

- 双击一级、二级倍率从离散 chip 改为 0.25x 步进 slider；持久化 key 与倍率语义不变。
- 系统状态栏从 bool 升级为 `show / hide / followControls`；
  旧 `showSystemStatusBar` 只作为读取迁移来源，新写入使用 `systemStatusBarMode`。
- `followControls` 直接读取 Reader 已有 controls visibility，不增加 Home/Pipeline 或 platform 侧第二 owner。

## 验证

- source settings contracts：PASS。
- Reader settings contract：PASS。
- ReaderSessionSettings focused tests：PASS。
- App preferences/settings focused tests：PASS。
- dev.161 network ownership / dual-stack DNS contract：PASS。
- Mihon durable replay contract：PASS。
- Gradle `MihonHostAbiTest` 与相关 Android Kotlin compilation：PASS；新增 FallbackDns nullable-hostAddress 警告已清除。
- 真机 debug 功能复核（保留 app data，不用于性能结论）：一级/二级倍率均实际渲染为 SeekBar；
  设备原有状态栏策略为“跟随控制栏”，Reader 初始 controls hidden 时 status/navigation bars 均 hidden，
  点击页面中心呼出并以“本漫画阅读设置”确认 Reader 控件后两栏均 visible，再次收起后两栏均 hidden，
  退出 Reader 后两栏恢复 visible。测试未执行翻页 swipe，也未修改该设备原有状态栏策略。
- 最终 `tool/check.sh`：PASS，exit 0。历史 dev.75–dev.338 ownership/contract gate、全仓 package/App tests、
  Android split debug APK build 与 Rust `media_core` gate 均完成并通过；analyzer 仅保留仓库既有 info-level lint debt。
