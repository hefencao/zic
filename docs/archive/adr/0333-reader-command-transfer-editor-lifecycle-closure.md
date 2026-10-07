# ADR 0333：Reader 命令、物理执行与编辑会话生命周期收口

状态：Accepted

## Context

对 `f47dbccf..7dbb3eb4` 的后续审查发现四个生命周期边界仍各自保留了第二处状态裁决：

1. vertical 程序化滚动的 completion callback 会直接把 `Interaction` 写成 `idle`。
   当 160ms 动画被真实 pointer drag 打断时，旧 Future 仍会完成，而 navigation revision 不一定变化，
   因此旧 callback 可以覆盖 ScrollNotification / raw pointer 已确认的 `dragging`。
2. `DownloadTransferOwner` 的 claim 原位降级会按 aggregate effective work mode 撤销 local preparation，
   但 claim removal 复制了另一套 scheduling 分支。最后一个 localOnly/full consumer 离开而 retained consumer 仍存活时，
   `DownloadSession.demanded` 仍为 true，旧 local restore 因而继续占 bounded operation slot。
3. 点击区域保存只绑定 mode，没有绑定打开它的编辑会话。旧保存 Future 可以在 cancel + reopen 之后关闭新 overlay。
4. continuous vertical 的普通 interior current 由 viewport center 推导，但真实首尾滚动边界会把 page-centered command clamp 到
   min/max scroll extent。短末页因此可能已经到真实 max extent，progress/current 却仍落在较前的短页。

另外审查指出三项可做的纯减法：scrub ratio 采纳有重叠遍历；decode refill 为只取一个最佳候选构造并排序完整列表；
全局点击设置与 Reader overlay 重复维护 action label/icon。最初没有复现所称 Android API stub 失败；
但后续 full gate 确实暴露了同类维护债务：dev.114/dev.117 以具体源码字符串锁死 one-frame refill 的实现写法，等价的单遍候选选择因此被误判为合同缺失。

## Decision

1. 程序化 vertical command completion 只负责“读取当前 ScrollMetrics 并 acknowledge command”，
   不再写 `Interaction`。dragging / scrolling / scrubbing / idle 的 authority 仍唯一来自 raw pointer 与 ScrollNotification 生命周期。
2. physical transfer claim 的新增、更新、移除都通过同一个 aggregate `_refreshClaimScheduling` 投影 execution permission。
   remaining retained claim 可保留 identity/session lifetime，但不能保留 local execution；effective mode 变为 retained 时，
   pending/active local preparation 必须立即收到 cancellation，slot 仍等 operation Future 真正退出后释放。
3. 每次打开点击区域编辑器创建独立 edit-session token。异步保存完成后只有 token 仍匹配时才能改变当前 overlay lifecycle。
   已经成功持久化的旧保存 MAY 更新 Reader settings snapshot，但 MUST NOT关闭、清空或重置后来打开的 editor/draft。
4. continuous vertical current mapping 保持两层语义：
   - 显式 slider scrub anchor 存在时，以该 selected page 作为 navigation identity；
   - 普通 interior scroll 使用 viewport center；
   - 真实 min/max ScrollPosition 分别映射首/末页；
   - 无 scroll range 时仅凭 geometry 无法唯一决定 current，保留既有 Reader current。
   章节边界 authority 仍是实际 ScrollPosition，不回退到 coverage-current。
5. scrub ratio 采纳只遍历 `0..anchor` prefix 加 `anchor+1..visibleMax` 的真实 visible tail，
   删除重复 anchor/visible 访问与重复 trace page id。
6. staged decode 的 transition-first-frame 与 one-frame 候选改为单遍 best selection，
   保留原 priority + key tie-break 和后续 waterline 顺序，不新增队列或 scheduler。
7. 全局点击设置复用 overlay 已有的 `readerGestureActionLabel/Icon`，不再维护第二份 action 文案/图标 switch。
8. 不做“删除全部手写 guard”的泛化清理。fresh full gate 暴露的 dev.114/dev.117 refill 检查已从具体比较式/排序器字符串
   收口为稳定 stage token + 已存在的 executable behavior regression 名称；完整 Dart suite 继续实际执行这些行为测试。
   所称 Android API stub 冲突本轮未复现，因此 Android 平台 guard 保持不变，后续只有 fresh 证据才能单独收口。

## Evidence

修复前新增四个回归均能稳定失败：

- animated continuous command 被 pointer drag 打断后，旧 completion 最终发布 `Interaction.idle`；
- 两 consumer 共享 physical id 时，移除最后一个 localOnly claim 后 retained survivor 令 local preparation cancellation 超时；
- save pending -> cancel -> reopen 后，旧 save completion 关闭新点击区域 overlay；
- 400×600 viewport、8 张约 100px 高页面在 max extent 时 current 为 6 而不是最终页 7。

上述四个回归在统一 ownership 修复后均通过。Reader navigation/geometry、DownloadTransferOwner/decode policy、
Reader controls/reader_runtime 的 focused suites 同轮全部通过。完整 repository/toolchain 结果记录在本提交验证中。
