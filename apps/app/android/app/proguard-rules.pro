# The startup path deliberately registers feature plugins by class name after
# the first Flutter raster. Keep both the class and its original name; the
# default Flutter rule permits obfuscation, which makes Class.forName fail in
# release builds.
-keep class dev.zic.comic_translation.ComicTranslationPlugin { *; }
-keep class dev.flutter.packages.file_selector_android.FileSelectorAndroidPlugin { *; }
-keep class dev.zic.localmedia.LocalMediaBridgePlugin { *; }
-keep class dev.zic.network.NetworkBridgePlugin { *; }
-keep class dev.zic.pluginhost.PluginHostBridgePlugin { *; }
-keep class dev.zic.readerruntime.ReaderRuntimePlugin { *; }
-keep class dev.zic.runtime.RuntimeBridgePlugin { *; }
-keep class dev.zic.texture.TextureBridgePlugin { *; }
-keep class com.flutter_rust_bridge.rhttp.RhttpPlugin { *; }
