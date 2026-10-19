package dev.zic.zic

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/** Keeps the existing Flutter task owners runnable; never executes or retries work. */
class BackgroundTaskService : Service() {
    companion object {
        private const val CHANNEL_ID = "zic_background_tasks"
        private const val NOTIFICATION_ID = 0x5A50
        private const val MAX_RUNTIME_MS = 6 * 60 * 60 * 1000L
        internal var running = false
            private set
        internal var onAction: ((String) -> Unit)? = null
        private var ready: ((Boolean) -> Unit)? = null
        private var instance: BackgroundTaskService? = null

        internal fun update(context: Context, state: Map<*, *>, callback: (Boolean) -> Unit) {
            if (state["active"] != true) {
                stop(context)
                callback(false)
                return
            }
            val intent = Intent(context, BackgroundTaskService::class.java)
            for ((key, value) in state) {
                when (value) {
                    is Boolean -> intent.putExtra(key as String, value)
                    is Number -> intent.putExtra(key as String, value.toInt())
                }
            }
            ready?.invoke(false)
            ready = callback
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent)
                else context.startService(intent)
            } catch (error: RuntimeException) {
                Log.w("zic.BackgroundTasks", "Cannot start foreground service", error)
                completeReady(false)
            }
        }

        internal fun stop(context: Context) {
            instance?.expectedStop = true
            context.stopService(Intent(context, BackgroundTaskService::class.java))
            completeReady(false)
        }

        private fun completeReady(value: Boolean) {
            val callback = ready
            ready = null
            callback?.invoke(value)
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var expectedStop = false
    private val deadline = Runnable { timeout() }

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "下载与整章翻译", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "显示任务进度，支持在后台继续执行与停止任务"
                    setShowBadge(false)
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                },
            )
        }
        // Older Android versions do not deliver onTimeout. Never hold a CPU
        // lease or a foreground notification indefinitely on those versions.
        handler.postDelayed(deadline, MAX_RUNTIME_MS)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || onAction == null) {
            expectedStop = true
            completeReady(false)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            val notification = notification(intent)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            running = true
            val active = intent.getIntExtra("downloads", 0) > 0 || intent.getIntExtra("translations", 0) > 0 ||
                intent.getIntExtra("preparing", 0) > 0
            if (active && wakeLock?.isHeld != true) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "zic:background-tasks").apply {
                        setReferenceCounted(false)
                        acquire(MAX_RUNTIME_MS)
                    }
            } else if (!active) {
                releaseWakeLock()
            }
            // Acknowledge only after Android has promoted this service.
            completeReady(true)
        } catch (error: RuntimeException) {
            Log.w("zic.BackgroundTasks", "Cannot promote foreground service", error)
            completeReady(false)
            expectedStop = true
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun notification(intent: Intent): Notification {
        val downloads = intent.getIntExtra("downloads", 0)
        val translations = intent.getIntExtra("translations", 0)
        val queued = intent.getIntExtra("queued", 0)
        val preparing = intent.getIntExtra("preparing", 0)
        val stopping = intent.getBooleanExtra("stopping", false)
        val title = if (stopping) "正在停止任务" else listOfNotNull(
            if (downloads > 0) "$downloads 个下载任务" else if (preparing > 0) "正在准备下载"
                else if (queued > 0) "$queued 个下载队列" else null,
            if (translations > 0) "整章预翻译" else null,
        ).joinToString(" · ")
        val total = intent.getIntExtra("total", 0).coerceAtLeast(0)
        val completed = intent.getIntExtra("completed", 0).coerceIn(0, total)
        val text = when {
            stopping -> "已保留完成的内容，正在等待任务退出"
            intent.getBooleanExtra("waiting", false) -> "等待下载条件，满足后继续"
            total > 0 -> "$completed / $total 页 · 可在后台继续"
            else -> "正在准备任务"
        }
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getBroadcast(this, 0,
            Intent(this, BackgroundTaskReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else Notification.Builder(this)
        builder.setSmallIcon(R.drawable.ic_background_tasks)
            .setContentTitle(title.ifEmpty { "ZIC 后台任务" })
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setProgress(total, completed, total == 0 || stopping)
        if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        if (!stopping) builder.addAction(Notification.Action.Builder(null, "停止任务", stop).build())
        return builder.build()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        timeout()
    }

    private fun timeout() {
        expectedStop = true
        onAction?.invoke("timeout")
        // Android requires stopSelf within seconds; Dart owners cancel and
        // drain independently without falsely releasing NetLane capacity.
        stopForeground(STOP_FOREGROUND_REMOVE)
        releaseWakeLock()
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        expectedStop = true
        onAction?.invoke("interrupted")
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onDestroy() {
        handler.removeCallbacks(deadline)
        running = false
        if (instance === this) instance = null
        releaseWakeLock()
        completeReady(false)
        if (!expectedStop) onAction?.invoke("interrupted")
        super.onDestroy()
    }
}

class BackgroundTaskReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        BackgroundTaskService.onAction?.invoke("stop")
    }
}
