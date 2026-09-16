# 2026-09-16 vertical fast-prefetch / direction-flip audit

输入：用户报告“手势向上快速滑动加载仍慢；手势向下回看卡顿”。基线为设备导出 `zic-debug-trace-2026-09-16T01-32-51.jsonl`。

基线方向翻转：`analyze_direction_flip_120hz_jank.py`记录1次active flip，DownloadDemand一次5 added + 5 removed，reconcile 8158us；`analyze_prefetch_direction_flip_jank.py`记录near-flip build median 3087us、away median 1394us。源码复核发现external-static使3/7全部获得one-frame Decode/Upload intent，而bridge旧mandatory集合无条件收集所有decode/upload source，因此工作集翻向绕过bridge。

基线快速首帧：170个matched `external-presentation-requested -> first-frame`，p50 65.2ms、p95 520.2ms、max1218.3ms，51个>100ms、23个>300ms。LiveCoordinator同时只允许一个offscreen external pending，快速fling会追上串行队列。

修复不扩大3/7、不提高NetLane并发：Reader profile只把offscreen external pending显式设为3（generic Coordinator仍为1）；bridge mandatory缩回foreground/visible + 2/1近邻，并让far static intent跟随source membership渐进进入；shared source identity采用desired role而不是旧role。

fresh arm64 Profile重新build+install后，20次快速手势向上再20次反向手势向下，导出 `zic-debug-trace-2026-09-16T02-08-52.jsonl`。结果：flip 1 added + 1 removed，`big_5x5=0`，bridge events=336，flip reconcile=6217us；external matched117，p50=55.1ms、p90=223.8ms、p95=283.7ms、max=552.0ms，>300ms=6；scene active interval >=35ms为0，taskFailed=0。平台cadence仍非完全clean，因此不宣称所有主观卡顿均已消失；本轮仅确认两个已定位结构性瓶颈显著收缩。

后续用户手测 `zic-debug-trace-2026-09-16T05-44-48.jsonl` 说明上一阶段仍有两处未收口：7个current-boundary reconcile中位9880us/max16382us，download/decode/upload阶段中位约1731/4802/3566us；唯一active direction flip再次是5 added + 5 removed、16382us，bridge events=0。第一处回溯到`DownloadTransferOwner`在每次role migration仍对完整3/7 retained set重复执行physical/version/canonical resolution；第二处说明完整static Decode/Upload intent仍可通过旧mandatory集合打穿bridge。

physical resolution现改为consumer acquire-time映射：retained logical id复用已选physical carrier，纯role/priority迁移不重新resolve，新logical id才解析。专项回归为3个初始identity解析3次、纯role迁移仍3次、滑窗新增1页才变4次。bridge继续只让foreground/visible+2/1近邻成为mandatory，far static跟随working-set渐进迁移。

另一条快滑延迟来自presentation grant与真实consumer生命周期不一致。仅禁止“无PageHost consumer”的grant会把speculative warm退化成mounted后才执行，因此最终边界不是扩大PageHost，而是由App composition注入detached external-static executor：Coordinator仍拥有exact grant与Reader=3 speculative cap；executor只消费Pipeline已有generation-scoped encoded-file/bytes capability，使用与mounted `LocalImagePlayer`相同的provider/cache identity提前解出第一帧进入Flutter ImageCache，并把同一grant完成一次。它不选择页、不执行network/retry、不建立隐藏Reader/Page widget或第二raster cache。为避免预热错误`ResizeImage` key，当前只执行source raster本身已落在physical viewport内的页面；近期真实样本为720×700（另少量720×662），覆盖当前设备workload。

fresh Profile真实重编译并安装后，固定y=900做20次手势向上快滑再20次手势向下回看，导出 `zic-debug-trace-2026-09-16T07-04-58.jsonl`。current-boundary reconcile 64个，中位1245us/max4264us，仅3/64>=3ms；download stage中位628us。active flip保持1 added + 1 removed，reconcile4015us，bridge events=225。detached prewarm共76 started / 76 prepared first-frame / 0 failure；可直接配对的start→prepared p50 40.2ms、p95 53.4ms、max67.5ms。35个实际进入visible集合的页面中32个已先ready；仅启动附近144–146页在visible后74.1–150.3ms出帧。71个后续mounted visible frame明确记录`prepared=true`。platform frame interval >=35ms为0，active-scroll WindowMetrics无unique outlier，taskFailed=0。presentation file lease仍会在prewarm和后续mounted provider各取得一次只读capability，当前read p50 6.2ms/p95 21.8ms/max28.9ms；由于黑块已消失且该I/O大多发生在offscreen，不新增provider registry/第二presentation cache owner。
