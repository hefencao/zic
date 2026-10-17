#include <jni.h>

#if defined(__aarch64__)
#include <sys/auxv.h>
#endif

// This library has no inference dependencies and uses the ABI's baseline ISA.
// Query it before loading the DotProd-compiled Hy-MT runtime or its dependencies.
extern "C" JNIEXPORT jlong JNICALL
Java_dev_zic_comic_1translation_LocalTranslationCpu_capabilities(JNIEnv *, jobject) {
#if defined(__aarch64__)
    return static_cast<jlong>(getauxval(AT_HWCAP));
#else
    return 0;
#endif
}
