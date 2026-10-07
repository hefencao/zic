# ADR 0222：Physical acquire before presentation projection；unsealed 首帧 decode 为 provisional prefix failure

- 状态：Accepted
- 版本：ZIC 0.31.0-dev.242

## 背景

07:51真机Trace中，同一verified-equivalent图片跨版本出现不同progress。旧版本physical owner已有约4.85MiB partial，切到新版本current后却从0建立新的exact physical session；同一轮neighbor页面则正常命中`verified-transfer-acquire-alias`。随后另一个版本进入时出现`candidateOwners=2`。源码确认`PipelineReaderSession.pageStream()`在demand reconcile前调用`DownloadRegistry.get(exact)`，而composition resolver对已存在exact session明确禁止late alias，因此presentation读路径反向夺取了physical creation authority。

同一Trace唯一decode `taskFailed`发生在WebP current首帧、source 786432 bytes且未sealed；同一图片后来在source增长到8,380,120 bytes后成功连续解码，证明该次错误不是终局损坏。

## 决策

1. physical `DownloadSession`创建只属于transfer acquire/reconcile owner。Pipeline presentation/read-only路径不得调用creating lookup。
2. `PipelinePageStream`以logical exact identity建立，但只持有Pipeline-owned non-creating resolver；`binding.accept()`完成demand reconcile/verified alias后才refresh到resolved physical session。
3. progress、fallback bytes、startup readiness等只读路径统一使用`find`。不存在physical owner时不得为了展示而创建一个。
4. DecodeSession仅在`source.unsealed && decodedDepth == 0`时，把decode exception投影为provisional prefix insufficiency：沿现有`WebpDecodePrefixHints`推进下一source阈值并等待source revision。sealed source或已有成功frame后的异常仍终局失败。
5. 不修改dev.241 rank曲线。跨session rank异常先通过physical owner统一消除；只有同一physical task上仍有证据时才调整policy参数。

## 否决

- 不做progress alias copy或UI进度映射补丁；那会掩盖双physical owner。
- 不late-merge两个已经存在且可能各有writer的session；消除非法precreation，保留acquire-time单writer边界。
- 不把所有unsealed decode exception永久吞掉；只有零成功frame的增长前缀可延期，sealed/post-frame异常仍失败。
