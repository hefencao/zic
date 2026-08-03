# dev.99 后续交接

唯一后续基线：`zic_v0.31.0-dev.99_frame-pipeline-timing.zip`。不得以 dev.98 或更早 ZIP、旧工作树、dev.97 锚点 transformer、未校验 libwebp tree 或记忆源码覆盖。

上一基线：`zic_v0.31.0-dev.98_libwebp-archive-exact-patch.zip`；其归档和精确补丁合同仍有效。

必读：

1. `AGENTS.md`
2. 本文件
3. `docs/ARCHITECTURE.md`
4. `docs/SPEC.md`
5. `docs/IMPLEMENTATION_PLAN.md`
6. `docs/IMPLEMENTATION_STATUS.md`
7. `docs/adr/0083-frame-pipeline-timing-and-local-artifact-ingress.md`
8. `docs/audits/dev99-frame-pipeline-timing-audit.md`
9. `docs/audits/dev99-validation-results.md`

下一份设备 trace 应先运行（dev.98 旧 trace 不含 `framePipelineTiming`，显示 0 属预期）：

```bash
python3 tool/analyze_frame_pipeline_trace.py zic-debug-trace-*.jsonl
```

重点判断 `dominantStage`：

- `workerReady`：进程预热/动态库加载未在首帧前完成；
- `sourceWait` 或 `outputReadyToPresent`：ingress 或 lane/调度等待；
- `nativeDecode`：libwebp/demux；
- `platformRetain`/`platformBlit`/`platformSchedule`/`platformReplace`：Android 原子 texture 节点；
- `platformOther`：总 platform upload 扣除上述子节点后的未归因平台工作；`platformUpload` 仅作总量核对，不参与 dominant；
- `platformResultDispatch`/`channelDispatch`：Android main thread 或 MethodChannel；
- `fallbackDecode`：Android texture 失败后退回 Flutter；
- `taskFailed`：同时检查 lane、role、laneQueue/execution/taskElapsed；
- 所有阶段低但可见画面仍停顿：需要新增 Flutter raster/compositor confirmation，而不是猜测 native decode。

不可改变：7/3、2/1、current/transition、lane 5/3/2、两个进程期 Dart decode isolate、libwebp 帧内单线程、两帧 successor、Reader 不拥有 session/transport/artifact/texture。

历史验证仍可查：`docs/audits/dev97-validation-results.md`、`docs/audits/dev98-validation-results.md`。
