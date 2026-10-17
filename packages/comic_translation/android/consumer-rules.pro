-keep class dev.zic.comic_translation.LocalTranslationNative { *; }
-keep class dev.zic.comic_translation.LocalHyMtNative { *; }
# ONNX Runtime constructs its Java values and metadata from JNI by name.
-keep class ai.onnxruntime.** { *; }
