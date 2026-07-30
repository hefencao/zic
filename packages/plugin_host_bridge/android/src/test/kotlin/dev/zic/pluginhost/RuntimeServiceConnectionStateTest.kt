package dev.zic.pluginhost

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RuntimeServiceConnectionStateTest {
    @Test
    fun staleDeathCannotInvalidateExplicitRebind() {
        val state = RuntimeServiceConnectionState()
        val first = requireNotNull(state.beginBinding())
        assertTrue(state.markConnected(first))
        assertTrue(state.markLost(first))

        val second = requireNotNull(state.beginBinding())
        assertNotEquals(first, second)
        assertTrue(state.markConnected(second))
        assertFalse(state.markLost(first))
        assertTrue(state.connectedGeneration == second)
    }

    @Test
    fun abandonedBindingAllowsExplicitRetryGeneration() {
        val state = RuntimeServiceConnectionState()
        val first = requireNotNull(state.beginBinding())
        assertTrue(state.markLost(first))

        val retry = requireNotNull(state.beginBinding())
        assertNotEquals(first, retry)
        assertTrue(state.markConnected(retry))
    }

    @Test
    fun closeInvalidatesLateCallbacksAndFutureBindings() {
        val state = RuntimeServiceConnectionState()
        val generation = requireNotNull(state.beginBinding())
        state.close()

        assertFalse(state.markConnected(generation))
        assertFalse(state.markLost(generation))
        assertNull(state.beginBinding())
    }
}
