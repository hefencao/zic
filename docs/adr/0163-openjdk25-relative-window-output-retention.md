# ADR 0163：OpenJDK 25 构建环境与相对窗口 / Output Retention 所有权

状态：Accepted

## 背景

dev.179 曾把 Android 构建组合收回 AGP 9.1.1 / Gradle 9.3.1 / JDK17，但用户本地已经以 Flutter 3.44、OpenJDK25、AGP9.3.1、Gradle9.5.0、compileSdk37工作，并指出 Flutter3.44固定 `test_api 0.7.11` 时 `test:^1.31.2` 会要求更新的 test_api而解析失败。工具链事实应以真实本地可构建组合为准，同时区分“运行Gradle的JDK”与“Android产物class-file target”。

设备 trace还显示：current从104切到105后，旧104 active download从priority1000降到`retained-background=0`，而另一较远页面获得previous priority780。源码根因是 `RoleResolver` 把previous current写成互斥`PageRole.last`，forward/backward窗口又跳过last；presentation keep错误吞掉了 immediate previous 的网络/解码槽。VibeVenera中last-output keep与offset-relative download/decode窗口是正交状态。

## 决策
1. Android构建组合恢复 AGP9.3.1、Gradle9.5.0、compileSdk37；Gradle daemon criteria使用OpenJDK25。
2. Java/Kotlin Android产物继续 `sourceCompatibility/targetCompatibility=17`、`JvmTarget=17`。构建JDK25不自动抬高Android class-file target。
3. workspace直接 `test`依赖统一使用`^1.25.0`，允许Flutter3.44固定test_api约束参与求解；lock只由真实`flutter pub get`生成。
4. `RoleWindow.roles`只表达相对current资源角色；previous current不再写成互斥`PageRole.last`，也不再从forward/backward slot跳过。
5. `RoleWindow.retainedIndex`独立表达上一current已上传output retention；HeuristicPolicy以upload-only `PageRole.last` demand叠加。
6. 相邻翻页时，同一页可同时是资源维度`previous/next`和presentation维度retained；immediate previous继续获得download priority780和后1decode角色。
7. 大跳页时，previous current若已离开encoded7/3窗口，retention只保已有output，不得制造download/decode demand。
8. current preemption、retained-receiving、NetLane5+1、Venera pressure-only抢占和rhttp framing不改变。

## 后果
- previous预下载不再因`last`presentation语义错位一页。
- output retention不会重新引入远端冗余下载，也不需要缩7/3或增加取消防抖。
- OpenJDK25作为Gradle构建JDK，Android运行时兼容仍由target17控制。
- ADR0162关于rhttp framing/Built-in Kotlin准备继续有效；其工具链版本选择由本ADR取代。
