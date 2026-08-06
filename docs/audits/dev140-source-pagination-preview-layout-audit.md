# dev.140 漫画源分页与预览布局审计

## 唯一基线

用户上传的 `zic-main.zip`。

## 修改

- 漫画源页新增原生/Mihon/Venera 分类、24 项显式分页和页码控制。
- Mihon 已安装/仓库插件新增语言分类；语言由插件声明或 source metadata 归一化。
- 详情预览删除固定 `124×190` 折叠列表和三槽位展开布局，统一为按原始顺序的等目标面积布局。
- 折叠态直接复用第一行；展开图片区域不超过屏幕高度 80%，居中箭头控制。

## 面积合同

每个 tile 的尺寸为：

```text
width  = sqrt(targetArea × aspect)
height = sqrt(targetArea ÷ aspect)
```

因此每个 tile 的容器面积均为 `targetArea`，最大/最小面积比为 1.0。宽高比只做有界归一化，图片内容仍以 `BoxFit.contain` 呈现。

## 未修改

Reader Pipeline、下载窗口、缓存、native、texture、插件 runtime 和 ABI均未修改。
