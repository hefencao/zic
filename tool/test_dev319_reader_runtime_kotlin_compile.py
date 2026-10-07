#!/usr/bin/env python3
"""Compile ReaderRuntimePlugin.kt against minimal Android/Flutter API stubs."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/reader_runtime/android/src/main/kotlin/dev/zic/readerruntime/ReaderRuntimePlugin.kt'
kotlinc = shutil.which('kotlinc')
if not kotlinc:
    print('SKIP: kotlinc is not installed for ReaderRuntime compilation')
    raise SystemExit(0)

STUBS = {
'android/os/Build.kt': r'''
package android.os
object Build {
    object VERSION { const val SDK_INT: Int = 37 }
    object VERSION_CODES {
        const val N: Int = 24
        const val O: Int = 26
        const val R: Int = 30
        const val VANILLA_ICE_CREAM: Int = 35
        const val BAKLAVA: Int = 36
    }
}
''',
'android/os/Debug.kt': r'''
package android.os
object Debug { @JvmStatic fun threadCpuTimeNanos(): Long = 0L }
''',
'android/os/Looper.kt': r'''
package android.os
class Looper
''',
'android/os/Handler.kt': r'''
package android.os
class Handler(val looper: Looper)
''',
'android/os/HandlerThread.kt': r'''
package android.os
class HandlerThread(val threadName: String) {
    val looper: Looper = Looper()
    fun start() {}
    fun quitSafely(): Boolean = true
}
''',
'android/app/Activity.kt': r'''
package android.app
import android.view.Window
open class Activity { val window: Window = Window() }
''',
'android/graphics/Color.kt': r'''
package android.graphics
object Color {
    const val TRANSPARENT: Int = 0
    const val BLACK: Int = -16777216
}
''',
'android/view/Display.kt': r'''
package android.view
class Display {
    val refreshRate: Float = 120.0f
    fun hasArrSupport(): Boolean = false
}
''',
'android/view/View.kt': r'''
package android.view
class View {
    val display: Display? = Display()
    var systemUiVisibility: Int = 0
    companion object {
        const val SYSTEM_UI_FLAG_LAYOUT_STABLE = 256
        const val SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN = 1024
        const val SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION = 512
        const val SYSTEM_UI_FLAG_FULLSCREEN = 4
        const val SYSTEM_UI_FLAG_HIDE_NAVIGATION = 2
        const val SYSTEM_UI_FLAG_IMMERSIVE_STICKY = 4096
    }
}
''',
'android/view/WindowInsets.kt': r'''
package android.view
class WindowInsets {
    object Type {
        @JvmStatic fun statusBars(): Int = 1
        @JvmStatic fun navigationBars(): Int = 2
    }
}
''',
'android/view/WindowInsetsController.kt': r'''
package android.view
interface WindowInsetsController {
    var systemBarsBehavior: Int
    val systemBarsAppearance: Int
    fun setSystemBarsAppearance(appearance: Int, mask: Int)
    fun show(types: Int)
    fun hide(types: Int)
    companion object {
        const val BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE = 2
        const val APPEARANCE_LIGHT_STATUS_BARS = 8
        const val APPEARANCE_LIGHT_NAVIGATION_BARS = 16
    }
}
''',
'android/view/FrameMetrics.kt': r'''
package android.view
class FrameMetrics {
    fun getMetric(id: Int): Long = 0L
    companion object {
        const val UNKNOWN_DELAY_DURATION = 0
        const val INPUT_HANDLING_DURATION = 1
        const val ANIMATION_DURATION = 2
        const val LAYOUT_MEASURE_DURATION = 3
        const val DRAW_DURATION = 4
        const val SYNC_DURATION = 5
        const val COMMAND_ISSUE_DURATION = 6
        const val SWAP_BUFFERS_DURATION = 7
        const val TOTAL_DURATION = 8
        const val INTENDED_VSYNC_TIMESTAMP = 10
        const val VSYNC_TIMESTAMP = 11
    }
}
''',
'android/view/Window.kt': r'''
package android.view
import android.os.Handler
class Window {
    var isFrameRatePowerSavingsBalanced: Boolean = true
    var statusBarColor: Int = 0
    var navigationBarColor: Int = 0
    val insetsController: WindowInsetsController? = null
    val decorView: View = View()
    fun interface OnFrameMetricsAvailableListener {
        fun onFrameMetricsAvailable(window: Window, frameMetrics: FrameMetrics, dropCountSinceLastInvocation: Int)
    }
    fun addOnFrameMetricsAvailableListener(listener: OnFrameMetricsAvailableListener, handler: Handler) {}
    fun removeOnFrameMetricsAvailableListener(listener: OnFrameMetricsAvailableListener) {}
}
''',
'android/view/Choreographer.kt': r'''
package android.view
class Choreographer {
    fun interface FrameCallback { fun doFrame(frameTimeNanos: Long) }
    fun postFrameCallback(callback: FrameCallback) {}
    fun removeFrameCallback(callback: FrameCallback) {}
    companion object { @JvmStatic fun getInstance(): Choreographer = Choreographer() }
}
''',
'io/flutter/plugin/common/BinaryMessenger.kt': r'''
package io.flutter.plugin.common
interface BinaryMessenger
''',
'io/flutter/plugin/common/MethodCall.kt': r'''
package io.flutter.plugin.common
class MethodCall(val method: String) { fun <T> argument(name: String): T? = null }
''',
'io/flutter/plugin/common/MethodChannel.kt': r'''
package io.flutter.plugin.common
class MethodChannel(messenger: BinaryMessenger, name: String) {
    interface Result {
        fun success(value: Any?)
        fun notImplemented()
        fun error(code: String, message: String?, details: Any?)
    }
    interface MethodCallHandler { fun onMethodCall(call: MethodCall, result: Result) }
    fun setMethodCallHandler(handler: MethodCallHandler?) {}
}
''',
'io/flutter/embedding/engine/plugins/FlutterPlugin.kt': r'''
package io.flutter.embedding.engine.plugins
import io.flutter.plugin.common.BinaryMessenger
interface FlutterPlugin {
    class FlutterPluginBinding(val binaryMessenger: BinaryMessenger)
    fun onAttachedToEngine(binding: FlutterPluginBinding)
    fun onDetachedFromEngine(binding: FlutterPluginBinding)
}
''',
'io/flutter/embedding/engine/plugins/activity/ActivityAware.kt': r'''
package io.flutter.embedding.engine.plugins.activity
interface ActivityAware {
    fun onAttachedToActivity(binding: ActivityPluginBinding)
    fun onDetachedFromActivityForConfigChanges()
    fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding)
    fun onDetachedFromActivity()
}
''',
'io/flutter/embedding/engine/plugins/activity/ActivityPluginBinding.kt': r'''
package io.flutter.embedding.engine.plugins.activity
import android.app.Activity
class ActivityPluginBinding(val activity: Activity)
''',
}

with tempfile.TemporaryDirectory(prefix='zic-reader-runtime-kotlin-') as directory:
    tmp = Path(directory)
    sources = [SOURCE]
    for rel, content in STUBS.items():
        path = tmp / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content.strip() + '\n', encoding='utf-8')
        sources.append(path)
    subprocess.run([kotlinc, *(str(p) for p in sources), '-d', str(tmp/'out.jar')], check=True)
print('ReaderRuntimePlugin Kotlin compilation: OK')
