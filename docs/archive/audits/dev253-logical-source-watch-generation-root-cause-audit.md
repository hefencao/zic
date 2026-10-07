# dev.253 根因审计：logical source watch 跨 physical generation 陈旧

## 输入
- 唯一代码基线：dev.252完整包。
- 真机Trace：`zic-debug-trace-2026-08-13T01-44-00.jsonl`，7763条事件。

## 设备事实
- `taskFailed=0`、`sourceDisabled=0`。
- pipeline-reader-5 page81在约80.42s成为current并停留约3.26s，之后约86.61s再次成为current并持续至少5s；两次host生命周期均`firstFrameReady=false`。
- 对应new physical session `download:145d1e7b4a896d24`约81.10s从memory artifact cache得到18,699,622 bytes，随后`sourceReady`与`artifactPromoted`均成功。
- 对应DecodeSession约77.92s进入`waitingSource`，后续多次收到priority=1000 decode demand，直至约93.74s teardown仍未离开waitingSource。
- 该logical resource约69.80s曾`verified-transfer-acquire-alias`加入旧physical `-286cf5527541dfd3`；旧physical约74.71s promoted并约75.48s退休/清理alias，之后同logical exact约80.47s启动new physical owner。Trace中这是唯一一例alias后又以同logical identity启动新physical owner。

## 根因
`LiveCoordinator._sourceListeners`以logical DownloadId去重，却不记录listener实际绑定的physical projection；demand移除不解绑，后续physical mapping换代时`_watchSource`提前返回。与此同时source revision consumption仍属于旧projection timeline。数据层已经ready，wake边却仍指向已退休owner，形成无failure的永久waitingSource。

## 收口
source-watch变为generation-aware binding；physical换代时旧listener、旧decode source consumption与旧DecodeSession机械失效，并在完整reconcile后从新projection统一wake。Ingress registry也禁止same-id新DownloadSession复用旧SourcePool ingress。未引入timer watchdog、额外source registry或Reader侧retry owner。
