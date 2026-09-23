# Next Chat Handoff

## 1. 唯一继续基线
- 稳定基准版本：`0.31.0-dev.328` / App `0.31.0+328`。
- 历史阶段基线验证覆盖：dev.196, dev.197, dev.198, dev.199, dev.203 bounded 抢占基准。
- 当前主任务：整理文档超长单行，并严格执行 handoff 与 status 门禁行数限制。
- 功耗审计基准：静态竖排阅读高功耗根因已定位，详见 `docs/audits/static-vertical-active-probe-2026-09-22.md`。

## 2. 必读顺序
1. `docs/DOCUMENTATION_POLICY.md`：文档职责与证据等级；
2. `AGENTS.md`：架构边界与无修改/最小修改规则；
3. `docs/ARCHITECTURE.md`：当前系统所有权与生命周期；
4. `docs/SPEC.md`：产品与工程长期规范；
5. `docs/IMPLEMENTATION_STATUS.md`：当前实现与验证矩阵。

## 3. 当前开放问题
- 静态竖排浏览功耗偏高（HeuristicPolicy 静态爆发上传、逐页尺寸异步重绘颠簸、首屏 6 屏大 cacheExtent、KeepAlive 15 页常驻与 scheduleFrame 调度）。
- 文档超长单行整理，严格保持 handoff/status 责任预算上限，杜绝单行堆砌历史。

## 4. 下一步命令
- `python3 tool/check_repo.py`
- `python3 tool/check_documentation.py`
- `tool/check.sh`

## 5. 不可改变的稳定边界
- 页面网络调度由共享 `NetLane` 唯一拥有，保持 normal 5 + current 高优先级保留槽 1（5个transport lease 与 current handoff）。
- 逻辑与解码窗口固定为前 7 / 后 3（7/3）及解码前 2 / 后 1（2/1）。
- Reader 仅消费不可变输出，不拥有 transport、session、cursor 或 texture。
- 传输租约竞争采用 ranked-transport-lease-reclaim；支持 active current-class demotion 与 新current waiter 的 40分 差值抢占。
- 物理准备限制在 max2 并设立 post-local network-admission rank barrier，在任何 NetLane task 启动前执行 physical-local-prepare，0-byte victim 自动重排 local prepare。
- 存储与缓存：支持 cold partial 与 verified-equivalent READY 复用；保持 SourceEpoch、generation 与 frameUploaded / framePresented 的代际单调性。
- rhttp transport不得再次增加64/256 KiB聚合；DownloadJob 为单一数据聚合 owner。
- Mihon 1.4/1.6 `NetworkHelper.client` 必须保留 canonical default-client 三件套：首位 `UncaughtExceptionInterceptor`、
  `UserAgentInterceptor`、以及委托 `network_bridge` 的 `CloudflareInterceptor`；默认 client 不加 Brotli。这是 plugin-host ABI 兼容边界，
  不得把这些兜底/验证语义迁到 Reader/Pipeline/Download。Mihon Injekt scope 同样由 plugin host 唯一拥有；`Application`、`NetworkHelper`、
  `Json(ignoreUnknownKeys=true, explicitNulls=false)` 为当前稳定 host singleton 合同。
  Mihon `mihon-runtime-transform-v3:<payload-sha256>` locator 的 chapter/page replay 坐标只授权一次 source-plan replacement，并把持久 carrier 绑定到实际 extension payload；
  非网络 source-owned `loadResource` failure 才可触发，SSL/EOF 继续归 DownloadJob。
  v1/v2 或 payload SHA 不匹配的 v3 locator 必须在 Reader/下载入口强制 source refresh，不得恢复旧 opaque plan；replacement unavailable/replay source failure 只交给既有
  terminal source-generation refresh handoff，Reader 当前页、章节下载命令与 whole-comic queue 各自在原 owner 内至多整章刷新一次；
  不在 Reader/Pipeline 新建 Mihon retry owner。显式 `refreshResource` 用 `freshGeneration=true` 重取 page list，并由 runtime
  在当前 generation 内按 source+locator 有界保留 fresh source request authority，resolve/re-resolve/runtime load 不得回退旧 opaque plan；source setting mutation
  推进 transport generation 时必须同步失效该 source 的 retained fresh/replay state。
- VeneraHttpCacheStore 维持 6h 有效期与 targeted force-miss 规约；Venera 阶段约束见 0169-venera-previous-request-plan-pressure-and-source-open-stages.md。
