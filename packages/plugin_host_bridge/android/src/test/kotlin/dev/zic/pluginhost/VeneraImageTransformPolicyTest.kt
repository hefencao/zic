package dev.zic.pluginhost

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VeneraImageTransformPolicyTest {
    @Test
    fun jmStyleBlockReorderIsEligibleForIsolatedImagePlane() {
        val script = """
            let modifyImage = (image) => {
                const num = 12
                let blockSize = Math.floor(image.height / num)
                let remainder = image.height % num
                let blocks = []
                for(let i = 0; i < num; i++) {
                    let start = i * blockSize
                    let end = start + blockSize + (i !== num - 1 ? 0 : remainder)
                    blocks.push({start: start, end: end})
                }
                let res = Image.empty(image.width, image.height)
                let y = 0
                for(let i = blocks.length - 1; i >= 0; i--) {
                    let block = blocks[i]
                    let currentHeight = block.end - block.start
                    res.fillImageRangeAt(
                        0,
                        y,
                        image,
                        0,
                        block.start,
                        image.width,
                        currentHeight,
                    )
                    y += currentHeight
                }
                return res
            }
        """.trimIndent()

        assertTrue(isIsolatedVeneraModifyImageCandidate(script))
    }

    @Test
    fun sourceStateAndBrowserCapabilitiesStayOnCanonicalContext() {
        assertFalse(
            isIsolatedVeneraModifyImageCandidate(
                "let modifyImage = (image) => Network.sendRequest('GET', url)",
            ),
        )
        assertFalse(
            isIsolatedVeneraModifyImageCandidate(
                "let modifyImage = (image) => typeof sourceHelper === 'undefined' ? image : sourceHelper(image)",
            ),
        )
        assertFalse(
            isIsolatedVeneraModifyImageCandidate(
                "let modifyImage = (image) => { try { return sourceHelper(image) } catch (_) { return image } }",
            ),
        )
    }
}
