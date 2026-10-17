package dev.zic.comic_translation

private object LocalTranslationCpu {
    external fun capabilities(): Long
}

internal object HyMtRuntimeLoader {
    // Linux AArch64 HWCAP: FP, ASIMD, CRC32, ATOMICS, ASIMDRDM, ASIMDDP.
    // These match the compiler features enabled by armv8.2-a+dotprod.
    private const val REQUIRED_CAPABILITIES =
        (1L shl 0) or (1L shl 1) or (1L shl 7) or (1L shl 8) or (1L shl 12) or (1L shl 20)

    fun load(
        loadLibrary: (String) -> Unit = System::loadLibrary,
        capabilities: () -> Long = LocalTranslationCpu::capabilities,
    ): UnsatisfiedLinkError? = try {
        loadLibrary("zic_translation_cpu")
        if (capabilities() and REQUIRED_CAPABILITIES != REQUIRED_CAPABILITIES) {
            UnsatisfiedLinkError("Hy-MT requires an ARMv8.2-A CPU with DotProd; select another model or API backend")
        } else {
            loadLibrary("zic_hymt")
            null
        }
    } catch (error: UnsatisfiedLinkError) {
        error
    }
}
