#!/usr/bin/env python3
"""Compile TextureBridgePlugin.kt against minimal Android/Flutter API stubs."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (
    ROOT
    / "packages/texture_bridge/android/src/main/kotlin/dev/zic/texture"
    / "TextureBridgePlugin.kt"
)

kotlinc = shutil.which("kotlinc")
if not kotlinc:
    print("SKIP: kotlinc is not installed for texture bridge compilation")
    raise SystemExit(0)

STUBS = {
    "android/os/Looper.kt": """
package android.os
class Looper {
    companion object {
        private val main = Looper()
        @JvmStatic fun getMainLooper(): Looper = main
        @JvmStatic fun myLooper(): Looper? = null
    }
}
""",
    "android/os/Handler.kt": """
package android.os
class Handler(val looper: Looper) {
    fun post(action: () -> Unit): Boolean { action(); return true }
    fun postAtFrontOfQueue(action: () -> Unit): Boolean { action(); return true }
}
""",
    "android/view/Surface.kt": """
package android.view
class Surface
""",
    "io/flutter/view/TextureRegistry.kt": """
package io.flutter.view
import android.view.Surface
interface TextureRegistry {
    fun createSurfaceProducer(): SurfaceProducer
    interface SurfaceProducer {
        fun id(): Long
        fun setSize(width: Int, height: Int)
        fun setCallback(callback: Callback?)
        fun release()
        val surface: Surface
        fun scheduleFrame()
        interface Callback {
            fun onSurfaceAvailable() {}
            fun onSurfaceCleanup() {}
        }
    }
}
""",
    "io/flutter/plugin/common/MethodCall.kt": """
package io.flutter.plugin.common
class MethodCall(val method: String) {
    fun <T> argument(name: String): T? = null
}
""",
    "io/flutter/plugin/common/BinaryMessenger.kt": """
package io.flutter.plugin.common
interface BinaryMessenger {
    interface TaskQueue
    fun makeBackgroundTaskQueue(): TaskQueue
}
""",
    "io/flutter/plugin/common/StandardMethodCodec.kt": """
package io.flutter.plugin.common
class StandardMethodCodec private constructor() {
    companion object { val INSTANCE = StandardMethodCodec() }
}
""",
    "io/flutter/plugin/common/MethodChannel.kt": """
package io.flutter.plugin.common
class MethodChannel {
    constructor(messenger: BinaryMessenger, name: String)
    constructor(
        messenger: BinaryMessenger,
        name: String,
        codec: StandardMethodCodec,
        taskQueue: BinaryMessenger.TaskQueue,
    )
    interface Result {
        fun success(value: Any?)
        fun error(code: String, message: String?, details: Any?)
        fun notImplemented()
    }
    interface MethodCallHandler {
        fun onMethodCall(call: MethodCall, result: Result)
    }
    fun setMethodCallHandler(handler: MethodCallHandler?) {}
}
""",
    "io/flutter/embedding/engine/plugins/FlutterPlugin.kt": """
package io.flutter.embedding.engine.plugins
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.view.TextureRegistry
interface FlutterPlugin {
    class FlutterPluginBinding(
        val binaryMessenger: BinaryMessenger,
        val textureRegistry: TextureRegistry,
    )
    fun onAttachedToEngine(binding: FlutterPluginBinding)
    fun onDetachedFromEngine(binding: FlutterPluginBinding)
}
""",
}

with tempfile.TemporaryDirectory(prefix="zic-texture-kotlin-") as directory:
    root = Path(directory)
    sources = [SOURCE]
    for relative, content in STUBS.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content.strip() + "\n", encoding="utf-8")
        sources.append(path)
    subprocess.run(
        [kotlinc, *(str(path) for path in sources), "-d", str(root / "out.jar")],
        check=True,
    )

print("Android texture bridge Kotlin compilation: OK")
