# ADR 0338：Native worker exit 由 pool 单次监听、退休与补位

状态：Accepted

## Context

native decode 与 source-write worker 都是 App composition 级长期 isolate。已有实现为了避免
worker 异常退出时 `response.first` 永久悬挂，在**每个请求**里执行：

`Future.any([response.first, _exited.then(...)])`

这能结算当前等待者，却把 process-lifetime `_exited` Future 当成 request-local signal：
正常 response 先完成时，本次 `then` 不会解除，成功请求越多，挂在同一 exit Future 上的
callback 越多。

同时，worker 真正退出后 pool 没有拥有 retirement。旧 `_run finally` 只把
`busy=false` 再次 `_pump()`；dead worker 仍留在可调度列表，而已完成的 exit Future 会让
后续每次请求立即失败。这里的问题不是 decode/source-write concurrency 数量，而是 worker
lifecycle owner 缺失。

## Decision

1. worker isolate exit 只在 worker 构造时安装**一个** listener。
   worker 保存至多一个当前 `_activeResponse` completer；exit 发生时由该单一 listener
   结算当前请求并完成 worker exit lifecycle。
2. 每个 request 只创建短生命周期 response port/subscription，并等待自己的 response completer。
   禁止再把长期 worker-exit Future 通过 `then` / `Future.any` 注入每个请求。
3. pool 是 worker liveness 的唯一 owner。exit callback 必须：
   - 从 live scheduling set 移除该 worker；
   - 让 `_pump` 永远跳过 `exited` worker；
   - 在 pool 仍存活时异步补齐 bounded worker 数量。
4. capacity 由真实 operation/run lifecycle 结算，而不是由 worker 是否仍在列表推断。
   decode/source-write pool 都单独维护 active-run count；worker exit 可以立即退休 scheduling identity，
   但 shutdown/idle 只有在原 `_run` 真正 unwind 后才认为 capacity 已释放。
5. decode pool 降级到单一 live worker时，background/non-current 不得占用最后一个 slot；
   current work 继续保留唯一 live capacity，直到 replacement worker ready。
6. replacement 仍由同一个 pool 创建，不增加第二 scheduler、retry owner 或无界队列。
   decode 与 source-write lifecycle 继续分离；source-write pending priority/cancellation contract 不变。
7. 不用 timeout 假装 native work 已退出；in-flight FFI 的资源释放语义仍要求真实 worker/operation exit。

## Regression / governance guard

private pool 没有向产品 API 暴露“杀一个 worker”的 test hook；本轮不为测试增加生产故障注入接口。
`tool/test_native_worker_exit_ownership.py` 因此固定当前结构合同：

- 两个 worker 类型都必须有单一 active-response exit settlement；
- pool 必须拥有 exit retirement 与 bounded replacement；
- scheduler 必须排除 `worker.exited`；
- active capacity 必须独立于 live worker list 结算；
- 禁止恢复 request-local `Future.any(... _exited.then(...))`。

普通 native contract、完整 Dart/Flutter gate 与 Rust/native build继续验证正常执行路径。
异常退出的实际 fault injection 仍属于测试工具层后续能力，不允许为它向产品公开 worker handle。
