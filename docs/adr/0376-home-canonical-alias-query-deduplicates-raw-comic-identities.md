# ADR 0376: Home canonical alias query deduplicates raw comic identities

**状态：Accepted**

## 背景

Reader 返回时的 Home rebuild 会为漫画合并别名偏好。原查询遍历 saved comics 与全部章节，
即使多个章节共享同一 raw comic ID，也反复调用 source canonical identity；Mihon 因而重复
解码 opaque ID。匹配的 Profile FrameTiming 为 53.935ms，BUILD 为 46.856ms；同一 UI 帧的
40 个 CPU 样本中，26 个包含偏好/别名调用链。原 Release 的 35.255ms 章节返回帧没有匹配
CPU 证据，仍单独保留，不能用此退出样本替代归因。
首次去重后仍匹配到 46.940ms FrameTiming、40.111ms BUILD：41 个帧样本中 23 个经过
别名/偏好查询。首页先对所有漫画合并偏好，再检查更新证据，使无更新漫画也反复解析
其它漫画候选。设备 85 条 saved 漫画仅 6 条带 sourceUpdateAt，确认可先排除无更新候选。
短路调整后两个退出帧的别名样本降至 1/20 与 2/18，但 GC 重叠仍分别约 25.1/14.9ms。
栈和源码还确认同次 Home 构建调用两次 `_libraryComics`，为更新与历史重复聚合/解析。
这证明重复工作，不能把全部 GC 债务归因到该处。

## 决策

在现有 `_canonicalComicAliases` 的单次同步查询内，用临时 Set 记录已检查的 raw comic ID。
目标 ID 已经解析，直接纳入 examined；saved 与 chapter 候选只在同来源且首次出现时解析。
候选的既有插入顺序、偏好 union/LWW、source-first canonical identity 与 saved offline fallback
保持。下一查询仍读取当前来源 authority，不能把临时去重扩成跨查询缓存、source generation
镜像或新的 owner。Reader、Pipeline、NetLane、workers、窗口/预算与 durable progress exit
barrier 保持原合同。
首页更新列表先检查现有只读更新证据，再检查同一合并入架偏好；只交换两个纯条件的
短路顺序，不新增批量投影或跨查询缓存，更新候选与历史列表语义保持。
同次同步 `_buildHomePage` 只取得一次现有只读 `_libraryComics`，分别过滤/排序更新和
历史列表。下一构建仍重新读取；不改变 source/GC/线程/资源所有权或 durable exit 合同。

## 验证与后果

有效 failing-first 使用相同两个 raw 别名，将每个别名的章节数从 1 增至 60；相同 rebuild 的
canonical 查询从 17 次增至 253 次，超过固定工作量边界。偏好 union、custom order 与 active
source 覆盖旧 saved identity 的断言均先通过，排除测试夹具失败。
新增无更新候选回归的有效 failing-first：8→32 本未更新漫画使查询 133→1261，超过
665 的线性增长边界；展示条件断言先通过。
新增空更新/历史列表回归在修改前确认 12 本漫画仍解析 24 次，展示断言通过，固定工作量
边界失败。三项组合后的最终源码专项 29 项、required-toolchain 门禁 2203 项、Rust 22 项
及三 ABI 的 native Release Profile/普通 minified Release 构建、JNI/FFI 检查均通过。
匹配的两个 Profile 退出帧 BUILD 为 14.933/25.838ms，别名样本为 5/23 与 3/22；
后一帧仍重叠 10.162ms GC。cached chapter return 仍重叠 15.557ms GC，不能关闭总体性能。
最终普通 Release 一键导出 8050 条事件、taskFailed=0；五次 slider 静置首帧、四次方向及
首尾跨章、五条已安装 Mihon 主列表版本/ABI 通过。其中三次为 0 字节起始的当前页下载，
首帧在松手后约 1.99/1.68/1.46s、下一输入前完成，无额外内容滑动。
接受范围限于三项查询冗余合同。旧普通 Release 35.255ms 和新 20.331ms 返回构建帧尚无
匹配 CPU，GC、入口/输入延迟、最终显示、全来源及原 112 项验收继续开放。
证据见 `docs/audits/home-canonical-alias-query-regression-2026-10-02.json`。
