package dev.zic.pluginhost

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VeneraBridgeInvocationDrainTest {
    @Test
    fun cancelledJsFinishKeepsPermitUntilBlockedNativeWorkExits() {
        val completed = ArrayList<String>()
        val drain = VeneraBridgeInvocationDrain<String> { requestId, _ ->
            completed.add(requestId)
        }
        assertTrue(drain.beginInvocation("cancelled"))
        assertTrue(drain.beginCall("cancelled", "http", activation = false))
        val entered = CountDownLatch(1)
        val unblock = CountDownLatch(1)
        val exited = CountDownLatch(1)
        val worker = Thread {
            entered.countDown()
            unblock.await()
            drain.endCall("cancelled", "http")
            exited.countDown()
        }
        worker.start()
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            drain.finish("cancelled")
            assertTrue(completed.isEmpty())
            assertEquals(listOf("cancelled"), drain.activeRequestIds())
        } finally {
            unblock.countDown()
            worker.join(2_000)
        }
        assertEquals(0L, exited.count)
        assertEquals(listOf("cancelled"), completed)
        assertTrue(drain.activeRequestIds().isEmpty())
    }

    @Test
    fun successfulResultAlsoWaitsForJsAndEveryAdmittedCall() {
        val completed = ArrayList<String?>()
        val drain = VeneraBridgeInvocationDrain<String> { _, result -> completed.add(result) }
        assertTrue(drain.beginInvocation("source"))
        assertTrue(drain.beginCall("source", "awaited", activation = false))
        assertTrue(drain.beginCall("source", "background", activation = false))
        drain.complete("source", "source-result")
        drain.endCall("source", "awaited")
        assertTrue(completed.isEmpty())
        drain.finish("source")
        assertTrue(completed.isEmpty())
        drain.endCall("source", "background")
        assertEquals(listOf("source-result"), completed)
    }

    @Test
    fun nativeExitBeforeJsFinishDoesNotPublishTheResult() {
        val completed = ArrayList<String?>()
        val drain = VeneraBridgeInvocationDrain<String> { _, result -> completed.add(result) }
        drain.beginInvocation("source")
        drain.beginCall("source", "http", activation = false)
        drain.endCall("source", "http")
        drain.complete("source", "result")
        assertTrue(completed.isEmpty())
        drain.finish("source")
        assertEquals(listOf("result"), completed)
    }

    @Test
    fun cancelledQueuedWorkRemainsAdmittedUntilItsExecutorFinallyRuns() {
        val completed = ArrayList<String>()
        val drain = VeneraBridgeInvocationDrain<String> { id, _ -> completed.add(id) }
        drain.beginInvocation("queued")
        drain.beginCall("queued", "not-started", activation = false)
        drain.finish("queued")
        assertTrue(completed.isEmpty())
        assertFalse(drain.beginCall("queued", "late", activation = false))
        drain.endCall("queued", "not-started")
        assertEquals(listOf("queued"), completed)
    }

    @Test
    fun repeatedFinishAndLateCallbacksDoNotReturnThePermitTwice() {
        val completed = ArrayList<String?>()
        val drain = VeneraBridgeInvocationDrain<String> { _, result -> completed.add(result) }
        drain.beginInvocation("source")
        drain.beginCall("source", "http", activation = false)
        assertFalse(drain.beginCall("source", "http", activation = false))
        drain.finish("source")
        drain.complete("source", "late-result")
        drain.finish("source")
        drain.endCall("source", "http")
        drain.endCall("source", "http")
        drain.finish("source")
        assertEquals(listOf<String?>(null), completed)
        assertFalse(drain.beginCall("source", "late", activation = false))
    }

    @Test
    fun activationCallsDrainWithoutInventingASourceInvocation() {
        val completed = ArrayList<String>()
        val drain = VeneraBridgeInvocationDrain<String> { id, _ -> completed.add(id) }
        assertTrue(drain.beginCall("activation", "first", activation = true))
        assertTrue(drain.beginCall("activation", "second", activation = true))
        drain.endCall("activation", "first")
        assertEquals(listOf("activation"), drain.activeRequestIds())
        drain.endCall("activation", "second")
        assertTrue(drain.activeRequestIds().isEmpty())
        assertTrue(completed.isEmpty())
    }

    @Test
    fun submissionFailureAndIndependentCallsRetireOnlyTheirOwnRequest() {
        val completed = ArrayList<String>()
        val drain = VeneraBridgeInvocationDrain<String> { id, _ -> completed.add(id) }
        for (id in listOf("rejected", "running")) {
            drain.beginInvocation(id)
            drain.beginCall(id, "call", activation = false)
            drain.finish(id)
        }
        drain.endCall("rejected", "call")
        assertEquals(listOf("rejected"), completed)
        assertEquals(listOf("running"), drain.activeRequestIds())
        drain.endCall("running", "call")
        assertEquals(listOf("rejected", "running"), completed)
    }

    @Test
    fun closeRejectsAdmissionAndKeepsPhysicalRegistrationUntilExit() {
        val completed = ArrayList<String?>()
        val drain = VeneraBridgeInvocationDrain<String> { _, result -> completed.add(result) }
        drain.beginInvocation("source")
        drain.beginCall("source", "http", activation = false)
        drain.complete("source", "discarded")
        assertEquals(listOf("source"), drain.close())
        assertFalse(drain.beginInvocation("new"))
        assertFalse(drain.beginCall("activation", "new", activation = true))
        drain.finish("source")
        assertEquals(listOf("source"), drain.activeRequestIds())
        drain.endCall("source", "http")
        assertTrue(drain.activeRequestIds().isEmpty())
        assertTrue(completed.isEmpty())
    }
}
