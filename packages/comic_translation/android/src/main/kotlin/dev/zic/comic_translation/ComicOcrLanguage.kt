package dev.zic.comic_translation

/** A language decision needs several reliable script characters, not an OCR score alone. */
internal object ComicOcrLanguage {
    fun choose(standard: List<Pair<String, Double>>, korean: List<Pair<String, Double>>): String? {
        fun evidence(lines: List<Pair<String, Double>>, script: (Char) -> Boolean): Double {
            var score = 0.0
            var count = 0
            for ((text, confidence) in lines) {
                if (confidence < 0.75) continue
                val chars = text.count(script)
                if (chars < 2) continue
                count += chars
                score += chars * confidence
            }
            return if (count >= 4) score else 0.0
        }
        val kana = evidence(standard) { it in '\u3040'..'\u30ff' }
        val hangul = evidence(korean) { it in '\uac00'..'\ud7af' }
        return when {
            hangul > 0 && hangul > kana * 1.2 -> "ko"
            kana > 0 && kana > hangul * 1.2 -> "ja"
            else -> null
        }
    }
}
