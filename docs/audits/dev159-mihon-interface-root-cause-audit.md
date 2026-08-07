# dev.159 Mihon接口根因、所有权与被否决方案审计

## 基线与证据

唯一代码基线：`zic_v0.31.0-dev.158_artwork-loader-compile-blocking-cleanup.zip`。Mihon接口参考：用户上传的 `mihon-main(3).zip`，只读。设备证据：两份 2026-08-07 trace。

Trace中 Roumanwu 的已有目录为80章，刷新结果变为0章后被 `chapter-catalog-regression-rejected/lost-catalog` 拒绝；禁漫天堂多次只投影1章；绅士漫画可投影1章并进入页面路径。它们说明catalog和resource请求必须分开诊断。

## 问题清单

### 编译/合同
- dev.157 gate和ADR把不存在于当前 `Source`接口的 `getChapterList`写成主入口，并把deprecated `fetchChapterList`放在combined之前。
- page resource丢失 `imageRequest(page)` 的method/body与动态Cookie/UA上下文。

### 产品
- 禁漫天堂：宿主按URL折叠完整SChapter，有机会保留不可读对象并丢弃另一个同URL对象。
- Roumanwu：错误目录入口把原80章刷新为0章。
- 绅士漫画：目录/页数成功不代表图片request plan正确；host直连缺少Mihon source request上下文。
- 插件restart/update存在deactivate-first窗口，候选激活失败可能把工作插件移除。
- 详情UI把合法空章节改写为“请WebView验证”，混淆catalog语义与验证错误。

### 性能/阻塞
- 不新增章节page preflight：目录刷新若逐章验证page list会把详情刷新变成正文下载/网络N+1。
- 普通图片继续走宿主流式transport，不把正文body改成Binder/JSON/Base64 RPC。

### 测试
- dev.157历史gate与`test_mihon_chapter_contract.py`固化了错误API顺序和URL去重，需要按当前Mihon接口更新，而不是迫使产品回退。

## 所有权清单

- `MihonRuntimeDriver`：唯一拥有Source API适配、live SChapter对象、page/image request plan与source runtime Cookie/interceptor桥接。
- `plugin_host` registry：唯一拥有active runtime session/sourceId owner与事务replacement。
- `plugin_host_bridge` controller：拥有installed manifest/payload选择；不得通过deactivate-first竞争registry生命周期。
- `catalog/resource_cache/downloads/pipeline`：继续分别拥有catalog投影、响应缓存、正文artifact/transport与Reader资源会话；Mihon driver不接管图片正文缓存/下载。
- `comic_details`：只消费catalog/failure；不得发明空目录=Cloudflare的业务语义。

## 被否决方案

- 不恢复synthetic“正文”单章节。
- 不按“开始阅读”标题或SChapter.url猜章节等价。
- 不在目录刷新中逐章调用getPageList做可读性预检。
- 不为绅士漫画新增App私有图片下载器、CookieJar或重试缓存。
- 不把普通图片完整body改走插件RPC。
- 不通过“先deactivate再activate、失败后再尝试恢复旧插件”实现restart/update。
