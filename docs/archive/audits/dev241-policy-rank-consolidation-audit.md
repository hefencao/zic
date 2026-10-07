# dev.241 policy rank consolidation audit

## 问题清单

- 编译错误：没有新增设备编译错误证据；当前环境工具链验证状态见validation。
- 产品错误：dev.237–240虽然修正了current/provider接管，但provider owner累积多套情况判断，同一priority/restart-cost信息可能在NetLane与owner得到不同结论。
- 性能问题：重复policy会导致已支付attempt过早切换或current过晚接管；full-body admission阈值也散落在owner，后续调参容易形成第二套策略。
- 测试错误：dev.237/238/240静态gate把历史`orphan/high-priority/strict-higher`实现细节冻结为永久合同，需要改为版本感知并验证统一rank语义。

## 所有权清单

| 状态/资源 | 正确owner | dev.241规则 |
|---|---|---|
| Reader role→semantic priority | Pipeline `HeuristicPolicy` | 只输出numeric rank |
| network restart-cost/effective rank/preemption margin | `NetLane` | `NetPolicyRank`唯一计算与比较 |
| provider exact/transport lease | `DownloadTransferOwner` | 只提供candidate/incumbent base rank，不复制scheduler规则 |
| provider claim live/orphan | transfer claim/lease | 只决定incumbent base rank来源 |
| same-exact | DownloadId identity | no-op invariant，不参与竞争rank |
| transport能否越过consumer dispose | transport capability | lifecycle invariant，不参与竞争rank |
| costly full-body prefix cost | `TransferRankPolicy` | preserved bytes→cost rank，demand→demand rank后统一比较 |

## 被否决方案

- 保留`if orphan -> if high priority`并仅抽常量：否决，只是给重复policy换名字。
- 把restart cost复制到provider owner：否决，NetLane已经是该成本的唯一owner。
- 把transport retained/same-exact也做成任意bonus：否决，这两者分别是lifecycle capability与identity no-op，不应通过分数绕过硬边界。
- 把current/1000写进sessions policy：否决，Reader语义到priority映射属于Pipeline。
- 将required completion直接改成network priority：否决，completion intent与竞争顺序正交；只在full-body admission demand rank中表达必须完成。

## 收口

本轮目标不是新增一套“更智能”的policy，而是删除重复policy owner。provider takeover与普通NetLane preemption共用同一effective rank；full-body catch-up也变成单一rank threshold。后续如果需要调优，只调rank输入/曲线，不再增加场景分支。
