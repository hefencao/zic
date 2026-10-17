package dev.zic.comic_translation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ComicOcrLanguageTest {
    @Test fun japaneseAndKoreanRequireStrongScriptEvidence() {
        assertEquals("ja", ComicOcrLanguage.choose(listOf("こんにちは" to 0.94), listOf("나" to 0.82)))
        assertEquals("ko", ComicOcrLanguage.choose(listOf("メ" to 0.85), listOf("안녕하세요" to 0.95)))
    }

    @Test fun coversEnglishAndAmbiguousSamplesStayUnresolved() {
        assertNull(ComicOcrLanguage.choose(emptyList(), emptyList()))
        assertNull(ComicOcrLanguage.choose(listOf("COMIC 中文標題" to 0.98), listOf("COMIC" to 0.99)))
        assertNull(ComicOcrLanguage.choose(listOf("こんにちは" to 0.55), listOf("안녕하세요" to 0.54)))
        assertNull(ComicOcrLanguage.choose(listOf("こんにちは" to 0.91), listOf("안녕하세요" to 0.92)))
    }
}
