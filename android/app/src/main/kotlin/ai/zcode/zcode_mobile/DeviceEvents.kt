package ai.zcode.zcode_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build

/**
 * Streams the physical events a phone has and a desktop does not: screen on and
 * off, unlocks, the charger going in and out, and Wi-Fi coming and going.
 *
 * Registered only while the app is alive — automation that must survive a kill
 * is a different, much heavier problem (foreground service + Doze), and the
 * rules that matter here are the ones that fire while the user is around.
 */
class DeviceEvents(private val context: Context, private val emit: (Map<String, Any>) -> Unit) {

    private var registered = false
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastLevel = -1
    private var lastCharging = false
    private var lastWifi = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent == null) return
            when (intent.action) {
                Intent.ACTION_SCREEN_ON -> emit(mapOf("type" to "screen_on"))
                Intent.ACTION_SCREEN_OFF -> emit(mapOf("type" to "screen_off"))
                Intent.ACTION_USER_PRESENT -> emit(mapOf("type" to "unlock"))
                Intent.ACTION_POWER_CONNECTED -> {
                    lastCharging = true
                    emit(mapOf("type" to "power_connected"))
                }
                Intent.ACTION_POWER_DISCONNECTED -> {
                    lastCharging = false
                    emit(mapOf("type" to "power_disconnected"))
                }
                Intent.ACTION_BATTERY_CHANGED -> onBattery(intent)
            }
        }
    }

    private fun onBattery(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val pct = if (scale > 0) level * 100 / scale else level
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        if (pct == lastLevel && charging == lastCharging) return
        lastLevel = pct
        lastCharging = charging
        emit(
            mapOf(
                "type" to "battery",
                "level" to pct,
                "charging" to charging
            )
        )
    }

    fun start() {
        if (registered) return
        registered = true
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
            addAction(Intent.ACTION_BATTERY_CHANGED)
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, filter)
            }
        } catch (e: Throwable) {
        }
        watchNetwork()
    }

    private fun watchNetwork() {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        try {
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(
                    network: Network,
                    caps: NetworkCapabilities
                ) {
                    val wifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                    if (wifi == lastWifi) return
                    lastWifi = wifi
                    emit(
                        mapOf(
                            "type" to if (wifi) "wifi_connected" else "wifi_disconnected",
                            "ssid" to currentSsid()
                        )
                    )
                }

                override fun onLost(network: Network) {
                    if (!lastWifi) return
                    lastWifi = false
                    emit(mapOf("type" to "wifi_disconnected", "ssid" to ""))
                }
            }
            cm.registerDefaultNetworkCallback(cb)
            networkCallback = cb
            val active = cm.activeNetwork
            val caps = if (active != null) cm.getNetworkCapabilities(active) else null
            lastWifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        } catch (e: Throwable) {
        }
    }

    private fun currentSsid(): String {
        return try {
            val wm = context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val ssid = wm.connectionInfo.ssid ?: ""
            if (ssid == "<unknown ssid>" || ssid == "0x") "" else
                ssid.removePrefix("\"").removeSuffix("\"")
        } catch (e: Throwable) {
            ""
        }
    }

    fun stop() {
        if (!registered) return
        registered = false
        try {
            context.unregisterReceiver(receiver)
        } catch (e: Throwable) {
        }
        networkCallback?.let {
            try {
                val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as? ConnectivityManager
                cm?.unregisterNetworkCallback(it)
            } catch (e: Throwable) {
            }
        }
        networkCallback = null
    }
}
