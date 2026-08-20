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
'android/view/Display.kt': r'''
package android.view
class Display {
    val refreshRate: Float = 120.0f
    fun hasArrSupport(): Boolean = false
}
''',
'android/view/View.kt': r'''
package android.view
class View { val display: Display? = Display() }
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
