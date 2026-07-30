package dev.zic.pluginhost

/// Generation-aware state for one explicit Android service binding.
///
/// A service-death callback from an older binding must never tear down a newer
/// explicit rebind. The client does not automatically replay requests after a
/// loss; a later caller starts a fresh generation through [beginBinding].
internal class RuntimeServiceConnectionState {
    private enum class Phase {
        IDLE,
        BINDING,
        CONNECTED,
        CLOSED,
    }

    private var phase = Phase.IDLE
    private var generation = 0L

    val activeGeneration: Long?
        get() = generation.takeIf {
            phase == Phase.BINDING || phase == Phase.CONNECTED
        }

    val connectedGeneration: Long?
        get() = generation.takeIf { phase == Phase.CONNECTED }

    fun beginBinding(): Long? {
        if (phase != Phase.IDLE) {
            return null
        }
        generation += 1
        phase = Phase.BINDING
        return generation
    }

    fun markConnected(candidateGeneration: Long): Boolean {
        if (phase != Phase.BINDING || candidateGeneration != generation) {
            return false
        }
        phase = Phase.CONNECTED
        return true
    }

    fun markLost(candidateGeneration: Long): Boolean {
        if (candidateGeneration != generation ||
            phase == Phase.IDLE ||
            phase == Phase.CLOSED
        ) {
            return false
        }
        phase = Phase.IDLE
        return true
    }

    fun close() {
        generation += 1
        phase = Phase.CLOSED
    }
}
