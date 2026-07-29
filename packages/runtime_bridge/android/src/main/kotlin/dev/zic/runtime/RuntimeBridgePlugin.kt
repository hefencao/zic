package dev.zic.runtime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class RuntimeBridgePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var networkReceiver: BroadcastReceiver? = null
    private var batteryReceiver: BroadcastReceiver? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopListening()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "currentEnvironment" -> result.success(currentEnvironment())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        startListening()
        emitCurrent()
    }

    override fun onCancel(arguments: Any?) {
        stopListening()
        sink = null
    }

    private fun startListening() {
        stopListening()
        val connectivity = connectivityManager()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = emitCurrent()
                override fun onLost(network: Network) = emitCurrent()
                override fun onCapabilitiesChanged(
                    network: Network,
                    networkCapabilities: NetworkCapabilities,
                ) = emitCurrent()
            }
            connectivity.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } else {
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) = emitCurrent()
            }
            @Suppress("DEPRECATION")
            context.registerReceiver(
                receiver,
                IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION),
            )
            networkReceiver = receiver
        }
        val battery = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) = emitCurrent()
        }
        context.registerReceiver(battery, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        batteryReceiver = battery
    }

    private fun stopListening() {
        networkCallback?.let { callback ->
            try {
                connectivityManager().unregisterNetworkCallback(callback)
            } catch (_: Throwable) {
            }
        }
        networkCallback = null
        networkReceiver?.let { receiver ->
            try {
                context.unregisterReceiver(receiver)
            } catch (_: Throwable) {
            }
        }
        networkReceiver = null
        batteryReceiver?.let { receiver ->
            try {
                context.unregisterReceiver(receiver)
            } catch (_: Throwable) {
            }
        }
        batteryReceiver = null
    }

    private fun emitCurrent() {
        val currentSink = sink ?: return
        mainHandler.post {
            if (sink === currentSink) {
                currentSink.success(currentEnvironment())
            }
        }
    }

    private fun currentEnvironment(): Map<String, Any> {
        val connectivity = connectivityManager()
        val networkAvailable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val network = connectivity.activeNetwork
            val capabilities = network?.let(connectivity::getNetworkCapabilities)
            capabilities != null &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        } else {
            @Suppress("DEPRECATION")
            connectivity.activeNetworkInfo?.isConnected == true
        }
        val unmetered = networkAvailable && !connectivity.isActiveNetworkMetered
        val batteryIntent = context.registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        )
        val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        return mapOf(
            "protocolVersion" to PROTOCOL_VERSION,
            "networkAvailable" to networkAvailable,
            "unmetered" to unmetered,
            "charging" to charging,
        )
    }

    private fun connectivityManager(): ConnectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    companion object {
        private const val METHOD_CHANNEL = "dev.zic/runtime_environment"
        private const val EVENT_CHANNEL = "dev.zic/runtime_environment/events"
        private const val PROTOCOL_VERSION = 1
    }
}
