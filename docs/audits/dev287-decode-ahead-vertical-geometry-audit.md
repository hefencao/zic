# dev.287 decode-ahead vertical geometry audit

## 设备事实

00:35 dev.286真机仍报告比例/缩放在页面稳定后才正常，否证dev.286“冻结layout + live visual extent”作为根因修复。代表时序：

- next2 identity `-4f580…` 于5.884986s decode得到648×2328；page20到6.210488s成为current，output/upload尺寸路径直到6.227453s才可用。
- next2 identity `-22993…` 于6.255154s decode得到608×2232；page21到6.611259s成为current，output/upload路径到6.638313s才可用。

因此正确ratio在页面成为current前约300–350ms已经存在于decode owner，却没有投影给Reader geometry。dev.281在active scroll延迟hidden next2 texture upload是正确的presentation政策，但它揭示了错误依赖：geometry尺寸不应等待texture/output。

## Root cause

尺寸事实被错误绑在`_ReaderPageHost/LocalImagePlayer` presentation生命周期。预解码已经获得frame width/height，但ReaderRuntime只能等UI output组成后才调用`_reportPageDimensions`。dev.280冻结visible geometry后，这种late knowledge会持续到idle；dev.286只能在错误sliver box中选择拉伸、裁切或留白，不能解决尺度跳变。

## 修复边界

尺寸事实从DecodeSnapshot只读上送Pipeline，再由ReaderRuntime现有ratio owner消费。active scroll只允许`visibleMaxIndex + 1 ... end`的future ratio进入当前layout snapshot；会改变viewport prefix的ratio仍等待idle。dev.286 presentation workaround完全移除。

## 真机判据

下一份Trace应看到future page先`pageDimensionsResolved`，随后在其仍位于真实visible tail之后时出现`pageGeometryPrepared(source=decode-ahead-ratio)`，并早于该page成为current。若decode尺寸已提前投影但页面仍在进入viewport后才改变尺度，则继续审计Sliver/item extent或PageAsset identity；不得恢复dev.286 OverflowBox。
