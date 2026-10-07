package dev.zic.pluginhost

/** Completion bookkeeping inside the existing bridge; no executor or queue. */
internal class VeneraBridgeInvocationDrain<T>(
    private val onDrained: (String, T?) -> Unit,
) {
    private class Request<T>(val invocation: Boolean) {
        val calls = HashSet<String>()
        var finished = false
        var result: T? = null
    }

    private data class Completion<T>(val requestId: String, val result: T?)

    private val lock = Any()
    private val requests = HashMap<String, Request<T>>()
    private var closed = false

    fun beginInvocation(requestId: String): Boolean = synchronized(lock) {
        if (closed || requests.containsKey(requestId)) return@synchronized false
        requests[requestId] = Request(invocation = true)
        true
    }

    fun beginCall(requestId: String, callId: String, activation: Boolean): Boolean =
        synchronized(lock) {
            if (closed) return@synchronized false
            val request = requests[requestId] ?: if (activation) {
                Request<T>(invocation = false).also { requests[requestId] = it }
            } else {
                return@synchronized false
            }
            !request.finished && request.calls.add(callId)
        }

    fun complete(requestId: String, result: T) = synchronized(lock) {
        val request = requests[requestId] ?: return@synchronized
        if (!closed && !request.finished) request.result = result
    }

    fun finish(requestId: String) {
        val completion = synchronized(lock) {
            val request = requests[requestId] ?: return@synchronized null
            request.finished = true
            retireIfDrained(requestId, request)
        }
        completion?.let { onDrained(it.requestId, it.result) }
    }

    fun endCall(requestId: String, callId: String) {
        val completion = synchronized(lock) {
            val request = requests[requestId] ?: return@synchronized null
            if (!request.calls.remove(callId)) return@synchronized null
            retireIfDrained(requestId, request)
        }
        completion?.let { onDrained(it.requestId, it.result) }
    }

    fun activeRequestIds(): List<String> = synchronized(lock) {
        requests.keys.toList()
    }

    fun close(): List<String> = synchronized(lock) {
        closed = true
        val active = requests.keys.toList()
        // WebView/driver teardown owns close notification. Keep admitted work
        // registered until its physical executor finally block exits.
        requests.entries.removeAll { (_, request) ->
            request.result = null
            request.calls.isEmpty()
        }
        active
    }

    private fun retireIfDrained(requestId: String, request: Request<T>): Completion<T>? {
        if (request.calls.isNotEmpty() ||
            (!closed && request.invocation && !request.finished)
        ) return null
        requests.remove(requestId)
        return if (!closed && request.invocation) {
            Completion(requestId, request.result)
        } else {
            null
        }
    }
}
