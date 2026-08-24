package dev.zic.zic

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Optional Android feature plugins live behind this class so loading
 * MainActivity does not resolve JNI/Rust plugin classes before Flutter has
 * submitted its first frame. The class is first initialized by a feature
 * channel call after startup, or by the explicit background preparation path.
 */
internal object DeferredAndroidPlugins {
    private val pluginClassNames = mapOf(
        "file_selector_android" to
            "dev.flutter.packages.file_selector_android.FileSelectorAndroidPlugin",
        "local_media_bridge" to "dev.zic.localmedia.LocalMediaBridgePlugin",
        "network_bridge" to "dev.zic.network.NetworkBridgePlugin",
        "plugin_host_bridge" to "dev.zic.pluginhost.PluginHostBridgePlugin",
        "reader_runtime" to "dev.zic.readerruntime.ReaderRuntimePlugin",
        "runtime_bridge" to "dev.zic.runtime.RuntimeBridgePlugin",
        "texture_bridge" to "dev.zic.texture.TextureBridgePlugin",
    )

    fun prepareRhttp(context: Context) {
        // RhttpPlugin's native method is intentionally private and the plugin
        // has no Dart method channel of its own. Invoke that lifecycle method
        // reflectively so its JNI context setup remains off the UI thread.
        val pluginType =
            Class.forName("com.flutter_rust_bridge.rhttp.RhttpPlugin")
        val plugin = pluginType.getDeclaredConstructor().newInstance()
        val init = pluginType.getDeclaredMethod("initAndroid", Context::class.java)
        init.isAccessible = true
        init.invoke(plugin, context)
    }

    fun create(name: String): FlutterPlugin? {
        val className = pluginClassNames[name] ?: return null
        val pluginType = Class.forName(className)
        val constructor = pluginType.getDeclaredConstructor()
        constructor.isAccessible = true
        return constructor.newInstance() as? FlutterPlugin
    }
}
