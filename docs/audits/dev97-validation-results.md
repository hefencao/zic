# dev.97 验证结果

## 基线与版本

- 唯一输入基线：`zic_v0.31.0-dev.96_local-webp-resident-single-thread-playback.zip`。
- 输出版本：`0.31.0-dev.97`；App：`0.31.0+97`。
- 中文提交标题：`修复 Reader 50% 无缝播放交接并压缩诊断 Trace`。
- Mihon、VibeVenera 与 libwebp 参考源码未修改、未并入。

## 设备 Trace 定位

用户 Trace：6486 条、4,147,260 bytes，无 JSON 解析失败。

在 22 次 `pageCurrent` 附近均观察到同一退化序列：

1. 旧 stable page 的 fractional observation 接近 50%。
2. `onPageChanged` 立刻发出新 stable page 的整数 observation，`targetIndex=null`。
3. outgoing demand 被 detach；有效 output 产生 `pageOutputReleased(reason=demand-detached)`。
4. 数十到数百微秒后的 scroll observation 又把旧页作为 transition 加回。

因此黑屏来自错误的 demand/output 生命周期断点，不是正文重新下载，也不是 7/3、2/1 或 lane 并发不足。

按本轮固定首事件时间桶规则离线投影该 Trace：6486 条事实投影为约 2387 个诊断桶，合并 4099 条高频样本，事件数下降约 63%。错误、retry、writer rejection、source disable 与 `pageOutputReleased` 不参与导出合并；导出容量淘汰另行计数。长 identity 的 hash+长度摘要还会进一步降低实际字节数。

## 源码与回归验证

以下检查通过：

- `python3 tool/check_repo.py`
- `python3 tool/check_dart_structure.py`：323 个 Dart 文件、121 个测试文件。
- `python3 tool/test_dart_library_directive_order.py`
- `python3 tool/test_pipeline_runtime_compile_boundary.py`
- dev.75–dev.97 全部静态所有权与回归门禁。
- `tool/test_vertical_geometry_cover_trace_contract.py`
- Android runtime dependency、Android Trace export。
- Venera network/native/header/preflight/bootstrap。
- Mihon entry、payload Context、ABI、classloader、只读 staging、chapter contract。
- source resource binding、Reader layout、Pipeline demand、Reader streaming、UI architecture、external login/settings。
- `tool/check_native_header.sh`
- libwebp CRLF/LF、幂等和半应用拒绝 fixture。
- Python 脚本编译和 shell 语法检查。

历史 dev.93 门禁中“50/50 必须 overlap”属于已失效合同，已迁移为 dev.97 的 stable/current midpoint 接管断言；dev.97 门禁会阻止恢复该旧断言。

## 编译闭包静态确认

- `ArtifactCacheStore` 通过显式 `ArtifactCacheStreamStore` 局部 cast 调用 `openArtifactStream`。
- `FrameRef` 通过显式 `FrameDecodeTiming` 局部 cast 读取 timing。
- `EncodedSource` 通过显式 `ExpectedLengthEncodedSource` 局部 cast 调用 `reserveExpectedLength`。
- libwebp prepared tree 不再使用 GNU patch fuzz；transformer 先统一换行，按 v1.6.0 函数锚点原子应用，并拒绝部分 token 状态。

## 未验证项

当前容器缺少 Flutter、Dart、Cargo、rustc、Gradle 与 ADB，因此未执行：

- `flutter analyze`
- Dart/Flutter package tests 与 App tests
- Rust 编译/测试
- Android debug/release 或 kernel snapshot
- 真机 50% 连续翻页、纹理复用和动画帧推进验证

`tool/check_webp.sh` 已启动，但当前容器无法解析 `chromium.googlesource.com`，上游 libwebp 1.6.0 fetch 以 exit 128 终止；因此精确上游 tree 的 patch/build smoke 仍列为外部未验证，不计为源码测试失败。

## 清理与删除

- 未删除生产源码文件或生产 facade。
- 全仓引用检查未发现仅测试使用、可安全删除的本轮相关兼容层。
- 打包前删除 `.deps`、`__pycache__`、`.pyc` 等生成物；ZIP 不包含 `.git`、`.dart_tool`、`build`、`.gradle`、`.class` 等产物。

## 完整包重新解压复验

- `unzip -t` 通过。
- 从最终 ZIP 独立解压得到 792 个文件；禁止生成物扫描为空。
- 独立副本执行 `tool/check.sh` 列出的全部 Python 门禁及 `tool/check_native_header.sh`：全部通过。长合同组因单次执行窗口限制分段运行，分段均无失败。
