# ADR 0314：纵排 external-static 首帧分阶段预呈现

## 状态
Accepted。部分 supersede ADR 0274；不撤销其 hidden native/provisional texture 在 active scroll 中的 defer 结论。

## 问题
最新真机 `zic-debug-trace-2026-09-16T00-49-20.jsonl` 证明纵排可见区 geometry 修复之后仍存在结构性黑块：稳定3/7 encoded window已有11个DownloadDemand，但滚动时只有4个DecodeDemand和1–3个UploadDemand，`runtimeStaticPages/staticWarmUploads=0`。fallback页可提前完成 native decode branch (`ended/depth=0`)，却直到成为 transition/visible 后才得到 external presentation request，因此 first-visible→first-frame p95约709ms、最大808ms。

根因不是网络窗口不足，而是两个不同 presentation path 被同一 `static` 布尔语义压平：
1. `ContentKind.fallback` 只清除 WebP transport-cost，没有把当前generation的精确静态图片签名投影回 Pipeline classification；
2. ADR 0274 的 active-scroll gate 随后把 hidden native texture 与 external Flutter static presentation 一起 defer。

## 决策
1. `ContentKind.fallback` 本身仍不是静态证明。PipelineRuntime只读取 `DownloadSession.readSourceMetadataPrefix()` 的generation-local bounded prefix，并复用共享 `sniffEncodedImageKind`；仅 JPEG/PNG/BMP/TIFF/ICO/AVIF/HEIF 等明确 non-WebP/non-GIF 图片进入 external-static evidence。HTML、source错误正文、未知fallback保持unclassified。
2. `PipelineController` 独立保存 `runtimeExternalStaticPages`。这是presentation-path事实，不是Reader/UI调度命令；`ReaderBinding`只透传该分类事实。
3. vertical dragging/scrolling/settling 时，hidden native/provisional static texture仍遵守 ADR 0274 defer，避免恢复当时实测约15–24ms的hidden platform blit竞争。
4. exact external-static page 可在既有RoleWindow 3/7 one-frame envelope内保留Decode/Upload intent；实际执行仍由 `StagedDecodeRefillPolicy` 逐个释放，visible/current/transition可按既有规则抢占。
5. 不增加page-count gate、estimated static-output budget、Reader-owned prefetch、NetLane容量或第二套memory owner。encoded speculative actual-read仍由既有共享budget裁决，native output仍归FrameBudgeter，Flutter fallback raster仍归App ImageCache。

## 验证
- Pipeline 53/53；PipelineRuntime 43/43；LiveCoordinator/ReaderBinding/DecodeRefill focused 52/52。
- 正例回归：opaque page 的 exact JPEG prefix 会产生 `mediaClassified(basis=encoded-prefix, animated=false)` 与 external-static policy fact。
- 反例回归：`Could not connect to mysql!` 这类 non-media fallback 不产生static classification。
- fresh Profile `zic-debug-trace-2026-09-16T01-08-49.jsonl`：page21–34 为14/14 first-frame-ready before visible。
- fresh Profile `zic-debug-trace-2026-09-16T01-10-52.jsonl`：page50–66 为17/17 READY、0 BLACK；其中page58–66在classification时 `localPresentationReady=false`，仍提前约2.16–2.29s完成首帧，证明external-static evidence而非旧cache负责预加载；taskFailed=0。

## 可证伪条件
若后续有效Profile trace在exact external-static已经提前分类、且其page host仍处于既有composition/cache envelope时再次出现大量 first-visible-before-first-frame，应检查 external-presentation pending/consumer lifecycle 与实际encoded-read budget，而不是扩大3/7、恢复UI预加载gate或取消native texture defer。若active-scroll出现新的15–24ms级native texture blit，则先确认是否错误把native/provisional页标成external-static。
