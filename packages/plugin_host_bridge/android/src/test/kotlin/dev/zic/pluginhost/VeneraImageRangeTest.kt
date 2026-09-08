package dev.zic.pluginhost

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VeneraImageRangeTest {
    @Test
    fun zeroHeightRangeIsAValidNoOp() {
        assertTrue(
            validateVeneraImageFillRange(
                targetWidth = 120,
                targetHeight = 8,
                sourceWidth = 120,
                sourceHeight = 8,
                x = 0,
                y = 8,
                srcX = 0,
                srcY = 0,
                width = 120,
                height = 0,
            ),
        )
    }

    @Test
    fun zeroWidthRangeIsAValidNoOp() {
        assertTrue(
            validateVeneraImageFillRange(
                targetWidth = 8,
                targetHeight = 120,
                sourceWidth = 8,
                sourceHeight = 120,
                x = 8,
                y = 0,
                srcX = 0,
                srcY = 0,
                width = 0,
                height = 120,
            ),
        )
    }

    @Test
    fun jmSmallImageScrambleRangesRemainValid() {
        val imageWidth = 120
        val imageHeight = 8
        val blocks = 20
        val blockSize = imageHeight / blocks
        val remainder = imageHeight % blocks
        var y = 0
        var emptyRanges = 0

        for (index in blocks - 1 downTo 0) {
            val start = index * blockSize
            val end = start + blockSize + if (index == blocks - 1) remainder else 0
            val height = end - start
            val empty = validateVeneraImageFillRange(
                targetWidth = imageWidth,
                targetHeight = imageHeight,
                sourceWidth = imageWidth,
                sourceHeight = imageHeight,
                x = 0,
                y = y,
                srcX = 0,
                srcY = start,
                width = imageWidth,
                height = height,
            )
            if (empty) emptyRanges++
            y += height
        }

        assertTrue(emptyRanges > 0)
        assertTrue(y == imageHeight)
    }

    @Test(expected = IllegalArgumentException::class)
    fun realSourceOverrunStillFails() {
        validateVeneraImageFillRange(
            targetWidth = 120,
            targetHeight = 80,
            sourceWidth = 120,
            sourceHeight = 80,
            x = 0,
            y = 0,
            srcX = 0,
            srcY = 70,
            width = 120,
            height = 11,
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun targetOverrunMatchesVeneraContract() {
        validateVeneraImageFillRange(
            targetWidth = 120,
            targetHeight = 80,
            sourceWidth = 120,
            sourceHeight = 80,
            x = 0,
            y = 70,
            srcX = 0,
            srcY = 0,
            width = 120,
            height = 11,
        )
    }

    @Test
    fun ordinaryRangeStillRequiresDrawing() {
        assertFalse(
            validateVeneraImageFillRange(
                targetWidth = 120,
                targetHeight = 80,
                sourceWidth = 120,
                sourceHeight = 80,
                x = 0,
                y = 20,
                srcX = 0,
                srcY = 40,
                width = 120,
                height = 20,
            ),
        )
    }
}
