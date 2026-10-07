package dev.zic.pluginhost

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeRuntimeWorkDrainTest {
    @Test
    fun closeWaitsForPhysicalExitWithoutBlockingTheCaller() {
        val drain = NativeRuntimeWorkDrain()
        val work = checkNotNull(drain.begin())
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val exited = CountDownLatch(1)
        val worker = Thread {
            entered.countDown()
            release.await()
            exited.countDown()
            work.finish()
        }
        worker.start()
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            val closed = drain.close()
            val reclaimed = closed.thenRun { assertTrue(exited.count == 0L) }
            assertFalse(closed.isDone)
            assertNull(drain.begin())
            release.countDown()
            reclaimed.get(2, TimeUnit.SECONDS)
        } finally {
            release.countDown()
            worker.join(2000)
        }
    }

    @Test
    fun duplicateCloseJoinsTheSameCompletion() {
        val drain = NativeRuntimeWorkDrain()
        val work = checkNotNull(drain.begin())
        val first = drain.close()
        assertSame(first, drain.close())
        assertFalse(first.isDone)
        work.finish()
        assertTrue(first.isDone)
        assertSame(first, drain.close())
        assertNull(drain.begin())
    }

    @Test
    fun duplicateRetirementCannotHideAnotherPhysicalCall() {
        val drain = NativeRuntimeWorkDrain()
        val first = checkNotNull(drain.begin())
        val second = checkNotNull(drain.begin())
        val closed = drain.close()
        first.finish()
        first.finish()
        assertFalse(closed.isDone)
        second.finish()
        assertTrue(closed.isDone)
    }

    @Test
    fun admissionCanTransferToAlreadyAdmittedChildWork() {
        val drain = NativeRuntimeWorkDrain()
        val activation = checkNotNull(drain.begin())
        val driver = checkNotNull(drain.begin())
        activation.finish()
        val closed = drain.close()
        assertFalse(closed.isDone)
        driver.finish()
        assertTrue(closed.isDone)
    }

    @Test
    fun closeAndAdmissionHaveOneAtomicBoundary() {
        repeat(100) {
            val drain = NativeRuntimeWorkDrain()
            val start = CountDownLatch(1)
            var admitted: NativeRuntimeWorkDrain.Work? = null
            val entrant = Thread {
                start.await()
                admitted = drain.begin()
            }
            entrant.start()
            start.countDown()
            val closed = drain.close()
            entrant.join(2000)
            assertFalse(entrant.isAlive)
            if (admitted != null) {
                assertFalse(closed.isDone)
                admitted!!.finish()
            }
            closed.get(2, TimeUnit.SECONDS)
            assertNull(drain.begin())
        }
    }

    @Test
    fun completionRunsOutsideTheAdmissionLock() {
        val drain = NativeRuntimeWorkDrain()
        val work = checkNotNull(drain.begin())
        val closed = drain.close()
        val checked = closed.thenRun {
            val probe = Thread { assertNull(drain.begin()) }
            probe.start()
            probe.join(2000)
            assertFalse("completion held the admission lock", probe.isAlive)
        }
        work.finish()
        checked.get(3, TimeUnit.SECONDS)
    }
}
