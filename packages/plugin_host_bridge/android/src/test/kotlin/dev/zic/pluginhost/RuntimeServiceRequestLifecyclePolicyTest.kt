package dev.zic.pluginhost

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RuntimeServiceRequestLifecyclePolicyTest {
    @Test
    fun activationSurvivesOneDeadServiceGeneration() {
        assertTrue(
            RuntimeServiceRequestLifecyclePolicy.shouldReplayAcrossServiceGenerationLoss(
                method = "activateVeneraRuntime",
                code = "runtime-service-died",
                completedReplays = 0,
            ),
        )
        assertTrue(
            RuntimeServiceRequestLifecyclePolicy.shouldReplayAcrossServiceGenerationLoss(
                method = "activateMihonRuntime",
                code = "runtime-service-disconnected",
                completedReplays = 0,
            ),
        )
    }

    @Test
    fun replacementIsNotAPluginOrSessionRetryPolicy() {
        assertFalse(
            RuntimeServiceRequestLifecyclePolicy.shouldReplayAcrossServiceGenerationLoss(
                method = "activateVeneraRuntime",
                code = "runtime-request-invalid",
                completedReplays = 0,
            ),
        )
        assertFalse(
            RuntimeServiceRequestLifecyclePolicy.shouldReplayAcrossServiceGenerationLoss(
                method = "invokeExternalRuntime",
                code = "runtime-service-died",
                completedReplays = 0,
            ),
        )
        assertFalse(
            RuntimeServiceRequestLifecyclePolicy.shouldReplayAcrossServiceGenerationLoss(
                method = "activateVeneraRuntime",
                code = "runtime-service-died",
                completedReplays = 1,
            ),
        )
    }
}
