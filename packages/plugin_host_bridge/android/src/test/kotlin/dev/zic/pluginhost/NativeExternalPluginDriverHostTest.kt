package dev.zic.pluginhost

import java.lang.reflect.InvocationTargetException
import org.junit.Assert.assertEquals
import org.junit.Test

class NativeExternalPluginDriverHostTest {
    @Test
    fun unwrapsMessageLessReflectionFailures() {
        val failure = InvocationTargetException(
            IllegalStateException("actual plugin failure"),
        )

        assertEquals("actual plugin failure", failure.sanitizedMessage())
    }

    @Test
    fun preservesContextFromMeaningfulOuterFailure() {
        val failure = IllegalStateException(
            "Mihon entry activation failed",
            InvocationTargetException(IllegalStateException("actual plugin failure")),
        )

        assertEquals("Mihon entry activation failed", failure.sanitizedMessage())
    }
}
