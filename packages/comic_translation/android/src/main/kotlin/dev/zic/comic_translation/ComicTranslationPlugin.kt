package dev.zic.comic_translation

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** Independent OCR and text workers. No Reader transport/decoder state. */
class ComicTranslationPlugin : FlutterPlugin {
    private var ocr: ComicTranslationOcrPlugin? = null
    private var local: ComicLocalTranslationPlugin? = null
    private var hyMt: ComicHyMtTranslationPlugin? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ocr = ComicTranslationOcrPlugin(binding.applicationContext, binding.binaryMessenger)
        local = ComicLocalTranslationPlugin(binding.binaryMessenger)
        hyMt = ComicHyMtTranslationPlugin(binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        ocr?.dispose()
        local?.dispose()
        hyMt?.dispose()
        ocr = null
        local = null
        hyMt = null
    }
}
