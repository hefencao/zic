# dev.138 VibeVenera 切页独立性审计

## 唯一基线

`zic_v0.31.0-dev.137_home-cover-primary-current-flow-pressure.zip`

## 产品问题

- 进入 Reader 后，目标页不能及时获得数据和首帧；用户观察到必须等第一张图片完整下载后才能切页。
- dev.137 的修复增加了比既有 priority lane 更强的全局资格门控，造成回归。

## 冗余/竞争路径

### 网络

已有 `NetLane`：

- 全局并发 5；
- current priority 1000；
- 1 个 high-priority reserved slot；
- priority 差达到 40 时可抢占低优先级任务。

dev.137 又加入 `DownloadFlowGate`，按 current holder depth 暂停同 source bucket 的其他 transport。这是第二套网络调度权威，并且绕过 target page 的 role/priority。

### 解码

transition 在 target coverage 0.15 时已建立，但 refill 顺序仍为：

```text
c>2 → n>1
```

因此即使网络已有目标前缀，transition 首帧仍必须等待 current depth 3。

## 修复

- 完整删除第二套网络门控和对应 Trace/test/analyzer 生产合同。
- DownloadJob 恢复只执行 transport、resume、chunk coalescing 和 session writer，不读取页面角色。
- transition depth 0 时执行独立 `t>0`；首帧后恢复原 staged 水位。
- Reader PageView、target coverage、7/3、7/5/3/2 与 5/3/2 不变。

## 拒绝方案

- 不把 flow gate 阈值从 depth 3 调成 1；任何 current-holder 驱动的全局网络资格都是错误所有权。
- 不关闭后台预下载或缩小窗口。
- 不让 Reader 直接启动目标页下载。
- 不将 transition 深水位提前到 current 之前，只提前首帧。

## 验收

新 Trace 中不应再出现 `downloadFlowPressure`。拖动产生 transition 后，即使 current depth 为 0，也应先看到 transition 的 `decodeRefill stage=t>0`；目标页首帧不依赖 current source sealed 或完整下载。
