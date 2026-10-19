package dev.zic.zic

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Activity permission/settings seam; no transport, job, or inference state. */
internal class BackgroundTasksHost(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.zic.zic/background_tasks")
    var resumed = false

    init {
        BackgroundTaskService.onAction = { action -> channel.invokeMethod("action", action) }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val state = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    if (state["active"] == true && !resumed && !BackgroundTaskService.running) {
                        result.success(false)
                    } else {
                        BackgroundTaskService.update(activity.applicationContext, state) { ready ->
                            result.success(ready)
                            if (ready) requestNotificationPermission()
                        }
                    }
                }
                "notificationSettings" -> openSettings(Intent(
                    if (Build.VERSION.SDK_INT >= 26) Settings.ACTION_APP_NOTIFICATION_SETTINGS
                    else Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                ).apply {
                    if (Build.VERSION.SDK_INT >= 26) putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                    else data = Uri.parse("package:${activity.packageName}")
                }, result)
                "batterySettings" -> openSettings(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS), result)
                else -> result.notImplemented()
            }
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33 || !resumed || activity.isFinishing || activity.isDestroyed) return
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val preferences = activity.getSharedPreferences("zic_background_tasks", Activity.MODE_PRIVATE)
        if (preferences.getBoolean("notification_permission_requested", false)) return
        preferences.edit().putBoolean("notification_permission_requested", true).apply()
        activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0x5A51)
    }

    private fun openSettings(intent: Intent, result: MethodChannel.Result) {
        try {
            activity.startActivity(intent)
            result.success(true)
        } catch (_: RuntimeException) {
            result.success(false)
        }
    }

    fun close() {
        BackgroundTaskService.onAction = null
        BackgroundTaskService.stop(activity.applicationContext)
        channel.setMethodCallHandler(null)
    }
}
