package dev.zic.pluginhost

/**
 * Defines which requests may survive replacement of the isolated runtime
 * service Binder generation.
 *
 * Only the initial runtime activation is transport-idempotent here: no plugin
 * session exists yet, so the host may preserve the same request across one
 * dead/disconnected Binder generation. Established-session operations are
 * deliberately excluded and recover through the higher-level session contract.
 */
internal object RuntimeServiceRequestLifecyclePolicy {
    private val activationMethods = setOf(
        "activateMihonRuntime",
        "activateVeneraRuntime",
    )
    private val replaceableServiceLossCodes = setOf(
        "runtime-service-died",
        "runtime-service-disconnected",
    )

    fun shouldReplayAcrossServiceGenerationLoss(
        method: String,
        code: String,
        completedReplays: Int,
    ): Boolean =
        completedReplays == 0 &&
            method in activationMethods &&
            code in replaceableServiceLossCodes
}
