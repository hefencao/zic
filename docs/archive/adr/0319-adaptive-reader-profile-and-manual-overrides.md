# ADR 0319：自适应阅读 profile 与手动设置轴解耦

## 状态
Accepted

## 问题
ADR 0318 将“自适应”收进了每漫画布局胶囊，并让“启用本漫画设置”同时 gate adaptive。这个模型把 adaptive 误缩成了阅读方向选择。

对照 VibeVenera 的实际实现后可以确认，adaptive profile 是跨行为输入：除了 reader mode，它还影响长按缩放、Animated 内容的预载策略，并可提供翻译源语言与自动翻译建议。ZIC 当前虽然还没有完整翻译功能，而且 Pipeline 调度有独立 ownership，但同一个漫画类型判定同样不应只服务布局。

如果把 adaptive 与方向绑定，会出现两个结构性问题：

- 用户固定阅读方向后，profile 被停止更新，手势等其它行为也失去 adaptive 信息；
- 后续翻译等消费者若要复用漫画类型，只能重新造第二套分类或重新引入交叉开关。

## 决策
1. `AdaptiveReaderProfile` 是 Reader 行为共享的类型/证据结果，不是布局 selector 的一项。
2. 全局 `adaptiveReaderEnabled` 与漫画级 `comicAdaptiveEnabled` 共同 gate adaptive；漫画级“使用自适应设置”独立于“启用本漫画设置”。
3. “启用本漫画设置”只 gate 手动 override。阅读方向只有 `跟随 / LTR / RTL / 纵向` 一个互斥轴。
4. 漫画级显式方向只压过 adaptive 的方向投影。classifier/profile 仍继续更新，并可供手势与未来其它能力消费。
5. 当前长按放大按“漫画显式覆盖 > 高置信 adaptive profile > 模式默认”解析：
   - vertical/webtoon profile 默认关闭；
   - paged/animated profile 默认开启；
   - 无可用 profile 时，vertical 默认关闭，paged 使用 global baseline。
6. 旧 `verticalLongPressZoom` 读取兼容为新的通用 `longPressZoomOverride`；新写入只使用后者。
7. 纵向拼接、长按放大和其它选项很少的离散 Reader 设置使用直接互斥胶囊/segment，而不是下拉框。数值范围继续使用 slider。
8. adaptive profile 可以以后增加翻译源语言、是否自动翻译等 typed 建议，但翻译执行仍由未来翻译子系统拥有。
9. adaptive 不得改变 ZIC 已有 Pipeline ownership：不得直接改 NetLane、download/decode window、prefetch eligibility 或 transport 生命周期。Animated preload 等 VibeVenera 行为只有在符合 ZIC Pipeline policy 时才能另行设计。

## 兼容
历史 `enabled=false && adaptiveEnabled=false` 继续解释为“没有启用手动漫画 override，但该漫画禁用 adaptive”，不再被迁移成启用的“跟随”方向策略。

旧 `verticalLongPressZoom` 若存在，读取为 `longPressZoomOverride`；持久化后使用新字段名。

## 后果
手动方向与 adaptive 不再互相排斥。用户可以固定 RTL/LTR/纵向，同时继续让漫画类型影响长按手势；以后翻译也可以消费同一 profile，而无需再造分类 authority。

UI 中“使用自适应设置”恢复为独立开关；阅读方向、纵向拼接、长按放大分别成为清晰的独立设置轴。ADR 0318 中关于 source settings ownership 的决策不受影响，但其第 7–9 项布局-only 模型由本 ADR 取代。
