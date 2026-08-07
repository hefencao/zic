# dev.159 验证结果

## 已完成

- 当前 Mihon主仓接口逐项对照：`Source.getMangaUpdate/getPageList`、`CatalogueSource` legacy委托、`HttpSource.imageRequest(page)`。
- dev.159 source-contract/request-plan/runtime-replacement静态gate。
- Mihon chapter contract、entry、payload Context、ABI routing、split classloader、read-only staging与network/Cloudflare Kotlin合同。
- Dart结构、directive order与Pipeline compile boundary。

## 完整回归与交付闭环

- 历史 `test_dev*.py` 共84个：83个通过；dev.98因唯一 dev.158基线缺 `third_party/source_archives/libwebp-1.6.0.zip` 跳过。dev.84/dev.85/dev.89/dev.147/dev.156中过时的旧Mihon API顺序/URL去重断言已更新到当前接口事实，没有恢复旧产品实现。
- Android runtime/Trace/texture、network browser/Cloudflare、Mihon entry/Context/ABI/classloader/read-only/chapter、Venera、source-resource、Reader/Pipeline/UI/native header合同通过。
- `tool/check.sh` 仅在上述 pinned libwebp archive缺失处停止；在此之前没有新的仓库门禁失败。
- 候选 Patch已在全新 dev.158临时Git基线执行 `git apply --check --index` 与实际 `git apply --index`；1075个发行文件内容/执行位与工作树一致，`.zic-workspace.json` 哈希未变化。
- 候选ZIP已独立解压复验：版本/禁入路径、documentation/Dart结构、dev.158/dev.159、Mihon chapter/entry/Context/ABI/classloader/read-only、source-resource、Reader/Pipeline/UI/native header通过。
- 写入本条结果后只变更验证审计；最终Patch/ZIP会重新生成并再次执行核心dev.159/Mihon平台复验，不再修改产品代码。

## 环境限制

当前环境若无Flutter/Dart SDK，则不声明Flutter analyzer/tests或APK构建通过；当前基线继续缺`third_party/source_archives/libwebp-1.6.0.zip`时，dev.98/source-build按既有规则跳过。
