# dev.232 same-epoch source rebind 根因审计

## 输入

- 唯一代码基线：`zic_v0.31.0-dev.231_required-exact-durable-target.zip`。
- 设备Trace：`zic-debug-trace-2026-08-12T00-38-02.jsonl`，5096条事件。

## 问题清单

### 运行时错误

- Trace出现3次`taskFailed`，全部为decode lane、`failureClass=partial-source`。
- page 211在source约1 MiB时失败，随后同页source增长后正常解码。
- page 212在source约3.9 MiB与6.0 MiB时连续失败，之后同页在sealed约14.6 MiB时正常出帧。
- 这不符合“未sealed source growth等待新revision、sealed后才判定终局损坏”的既有边界。

### durable target

- 本Trace未出现`stored-required-exact-alias`，因此没有覆盖dev.231的Reader + required chapter同physical transfer设备验证场景；不能据此把dev.231设备验证标记为完成。

## 根因

`Ingress.rebuild(epoch: currentEpoch)`会替换Reader-local `EncodedSource`对象，但`DecodeSession._bind()`此前只检查`_epoch == epoch`。因此同epoch rebuild后：

- projection/snapshot指向新source；
- DecodeSession cursor仍可能绑定旧source；
- decode错误会被归因到当前新source的`sourceLength/sourceSealed`，形成看似“未sealed partial失败”的错位诊断。

epoch代表内容世代，不代表具体native source handle identity。缺失的owner事实是cursor绑定的source对象本身。

## 修复

- `DecodeSession`增加`_boundSource`。
- `_bind()`只有在epoch相同且`identical(_boundSource, source)`时才复用cursor。
- same-epoch source replacement强制release旧cursor/holder并重新绑定当前projection source。
- partial-prefix restart/release同步维护`_boundSource`。
- 新增Dart行为回归：同epoch`projection.rebuild()`后cursor factory创建次数必须从1变为2。

## 被否决方案

- 不把所有未sealed decode异常吞掉；那会掩盖真实cursor/FFI错误。
- 不增加LiveCoordinator定时retry；现有source revision wake已经足够。
- 不通过缩小decode窗口或降低previous优先级绕开失败。
- 不让Reader管理source/cursor lifecycle。
