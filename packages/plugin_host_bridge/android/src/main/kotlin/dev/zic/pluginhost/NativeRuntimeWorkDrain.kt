package dev.zic.pluginhost

import java.util.concurrent.CompletableFuture
import java.util.concurrent.atomic.AtomicBoolean

/** Tracks physical work already admitted by its owner; no executor or queue. */
internal class NativeRuntimeWorkDrain {
    private val lock = Any()
    private val completion = CompletableFuture<Unit>()
    private var closing = false
    private var active = 0

    inner class Work internal constructor() {
        private val finished = AtomicBoolean(false)

        fun finish() {
            if (!finished.compareAndSet(false, true)) return
            val drained = synchronized(lock) {
                check(active > 0)
                active--
                closing && active == 0
            }
            // Completion callbacks may dispatch to Main or retire another owner.
            // Never run them while holding the admission lock.
            if (drained) completion.complete(Unit)
        }
    }

    fun begin(): Work? = synchronized(lock) {
        if (closing) return@synchronized null
        active++
        Work()
    }

    fun close(): CompletableFuture<Unit> {
        val drained = synchronized(lock) {
            closing = true
            active == 0
        }
        if (drained) completion.complete(Unit)
        return completion
    }
}
