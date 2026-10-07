# dev.253 验证结果

## 基线与输入

- 唯一代码基线：`zic_v0.31.0-dev.252_resume-safe-flow-and-sealed-ingress.zip`。
- 真机输入：`zic-debug-trace-2026-08-13T01-44-00.jsonl`。
- 当前候选：Source `0.31.0-dev.253` / App `0.31.0+253`。

## 变更范围

本轮只收口Reader-local source generation绑定：logical DownloadId的source watch显式携带当前physical `DownloadSession`与`DownloadIngressProjection`；physical generation变化时解绑旧listener、清空旧source revision消费状态、取消该logical页decode lane work并机械失效旧DecodeSession，再从新projection恢复source wake。`DownloadIngressProjectionRegistry`遇到same DownloadId但新的`DownloadSession`对象时必须新建Reader-local ingress/native source，不得继承旧generation。没有新增timeout/watchdog，也没有修改3/7、动画frame credit、consumer pacing、NetLane、partial/progress/provider/durable ownership。

## 工作树验证

- dev.205–dev.253历史/ownership gate：**49/49 PASS**，`max_workers=8`。
- 核心门禁：**10/10 PASS**：documentation responsibility、Dart structure、Pipeline runtime compile boundary、Pipeline demand stability、Reader streaming contract、UI architecture、test quarantine、Android runtime dependency、Android texture bridge Kotlin compile、dev.139 current-documentation consistency。
- Dart structure：361个Dart文件 / 135个test文件。
- dev.218历史source-wake gate已做版本感知：dev.253起要求从`_sourceWatches[id]?.projection`读取当前physical generation revision，不恢复`ingresses.find(logicalId)`旧假设。

## 完整入口

`tool/check.sh`已执行，仍在第一项因唯一dev.252基线缺少以下pinned archive停止：

`third_party/source_archives/libwebp-1.6.0.zip`

没有从历史包或文件库补入该归档。

## 工具链限制

当前环境无Dart / Flutter / Cargo，因此不得宣称Dart行为测试、Flutter analyze/build或Rust tests已执行。Kotlin compile boundary实际执行并通过。

## 发行树

- dev.252→dev.253 `git apply --check --index`：PASS。
- `git apply --index`：PASS。
- packaged `replay.py` 在第三份独立dev.252 Git baseline：PASS，`missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`。
- patch reconstructed tree：dev.205–253 **49/49 PASS** + 核心 **10/10 PASS**，`max_workers=8`。
- full ZIP extracted tree：dev.205–253 **49/49 PASS** + 核心 **10/10 PASS**，`max_workers=8`。
- patch/full ZIP逐文件比较均为 `missing=0 / extra=0 / content=0 / executable-bit=0 / type=0`。
