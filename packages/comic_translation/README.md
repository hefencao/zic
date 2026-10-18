# Comic translation

漫画图片的独立 OCR、翻译和文字覆层。设置入口为“设置 → 漫画翻译”；Reader 底栏翻译按钮
单击开关翻译，长按提供本漫画原文语言、OCR 精度、内容、指示器和重试，右上进入全局翻译设置。
模型/API、目标语言、翻译档位、上下文和预读仅全局设置；OCR 四项可按漫画覆盖或跟随全局，精度切换复用模型。高级参数默认折叠。日/韩语自动采样判断并按漫画记忆，手动选择优先。
图片先呈现，译文使用相同坐标跟随缩放旋转；单击译文气泡可查看原文。
动图保持原始播放并显示暂不支持翻译。

核心引擎、模型 schema v5、分组和排版来源为 vibevenera
`e27265211f71b6f93cf2f6d58b97771fe6e80c92`。迁移将 App 全局依赖替换为显式完整文件输入、
独立配置与 secrets、可等待的关闭、共享网络准入及通用 Reader presentation extension。
原项目 GPL-3.0 许可证见 `LICENSE`；PaddleOCR vendored source、原 revision 和 Apache-2.0 许可证
保留在 `android/ppocr-sdk/`。本地模型遵循各模型 manifest 中的许可证。

Android OCR 使用 PaddleOCR ONNX/OpenCV，支持自动、日、英、中与独立韩语识别器。
本地文本翻译支持 Hy-MT1.5 1.8B 2-bit GGUF 和导入 CTranslate2 模型包；本地文本 runtime 为 arm64。
Hy-MT 需要 ARMv8.2-A/DotProd；基线 JNI 在加载优化库前检查 CPU 能力，不兼容时可改选其他模型或 API 后端。
模型通过长度、SHA-256 和原子发布校验，支持中断后的下载恢复。
OCR 切换保留 detector；相同翻译模型跨漫画复用，最后租约后最多保温 30 秒，后台/内存压力等待调用退出后回收。
内容缓存的 JSON/base64 编解码与 OCR 摘要在存储 worker 执行；缓存命中不加载推理模型。
分组仅在单次解析中复用密集蒙版几何，避免成对比较时重复展开与扫描。
OpenAI-compatible 与 DeepL 使用显式 API profile，不自动回退到远程。
远程仅接收文字；API key 保存于 App 私有 `translation/comic_translation_secrets.json`，不进入库备份。

从仓库根目录准备锁定的 Android 依赖并构建：

```bash
python3 tool/prepare_translation_android.py
./tool/build_android.sh debug
python3 tool/check_android_translation.py --apk apps/app/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk
```

准备脚本使用 `.deps/comic_translation_native/`；可通过 `ZIC_TRANSLATION_NATIVE_ROOT` 指向同格式目录。
首次准备需要 Android SDK/NDK、CMake/Ninja/Git 以及锁定第三方源码的网络访问。
构建和运行入口自动准备依赖；CI 将同一源码构建结果传递到 Flutter job。
Android APK 带依赖版本、许可证和 JNI/依赖闭合检查；不依赖 vibevenera checkout 或其构建目录。
llama.cpp 使用固定上游基线 `031ddb2e08962837c899374297da75f91cc0157d` 加仓库内 Q2_0c/KleidiAI
补丁，重现源项目 `a2baedad71a4d5685c83fe1939bb2e5f94e77f35` 的代码；准备阶段核对完整补丁与摘要。

```bash
cd packages/comic_translation
flutter test test
```
