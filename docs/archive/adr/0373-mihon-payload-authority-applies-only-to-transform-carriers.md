# ADR 0373: Mihon payload authority applies only to transform carriers

**状态：Accepted**

## 背景

普通 Release 的真实 Pixiv 历史章节入口在加载新 manifest 后仍被 source-locator gate 拒绝。
`resourceAuthorityRevisionForSource` 提供已安装插件的 payload authority，
但标准客户端恢复 host-direct 后，普通章节的 source revision 不携带 runtime-transform authority。
共享 compatibility gate 对所有 Mihon 章节比较 payload 后缀，因而连有效的新 direct manifest 也要求再次刷新。
隔离 adapter 的 catalog/request/media 探针不经过这条持久化 Reader 入口，不能替代该验收。

## 决策

仅 revision 末尾携带完整 `mihon-runtime-transform-v3:<SHA-256>` authority 的章节参与当前 payload 比较。
普通 HTTP/replay-capable Mihon 章节不因插件存在 payload authority 而强制刷新。
既有 v1/v2、缺 replay 坐标的 Mihon resource、旧 Venera locator 和 Home 快照占位页仍须刷新。
当前 payload 不匹配的有效 v3 carrier 仍须在消费前刷新；刷新为 valid direct manifest 后正常完成 preparation。

同一现有 helper 继续供 Reader preparation、下载命令与 version-reuse preparation 使用。
不增加 transport、retry、revision 或 source-eligibility owner；不改变 Reader、NetLane、worker、窗口和预算。

## 验证与后果

修改生产代码前，带 current installed authority 的 direct locator、普通 HTTP 章节和
旧 payload 刷新为 direct manifest 的 preparation 三条行为测试失败，最后一条复现真机原错误。
39 项专项、2192 项 Dart/Flutter 与 Rust22 全门禁、三 ABI 构建通过。
普通 Release 原 Pixiv 入口已正常直连并独立发布首帧；6424 条完整 Trace 验证三次 slider
松手后无需内容滑动即可出图、四次跨章方向与首尾落点，以及主列表五条 Mihon 版本/ABI。
该验收不关闭独立性能、最终显示和全来源条件；完整证据和仍未验范围见
`docs/archive/audits/direct-mihon-payload-authority-regression-2026-10-02.json`。
