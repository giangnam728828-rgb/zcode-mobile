package ai.zcode.zcode_mobile

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import rikka.shizuku.Shizuku

/**
 * Everything that needs more than a normal app: root, Shizuku, and the handful
 * of system switches that a phone makes hard to reach.
 *
 * The two privileged channels are deliberately interchangeable — callers ask
 * for "whatever works" and get back which one answered. Both end up running
 * `sh -c`, so the feature set is identical; only the doorway differs.
 */
object Privilege {
    const val REQUEST_SHIZUKU = 0x5A01
    const val REQUEST_NOTIFICATIONS = 0x5A02

    private const val CHANNEL_ID = "zcode.automation"
    private var rootProbe: Pair<Long, Boolean>? = null

    // ------------------------------------------------------------------ status

    fun rootAvailable(force: Boolean = false): Boolean {
        val cached = rootProbe
        val now = System.currentTimeMillis()
        if (!force && cached != null && now - cached.first < 30_000) return cached.second
        val ok = try {
            val p = ProcessBuilder("su", "-c", "id").redirectErrorStream(true).start()
            if (!awaitExit(p, 4000)) {
                p.destroy()
                false
            } else {
                val text = p.inputStream.bufferedReader().readText()
                p.exitValue() == 0 && text.contains("uid=0")
            }
        } catch (e: Throwable) {
            false
        }
        rootProbe = now to ok
        return ok
    }

    fun shizukuRunning(): Boolean = try {
        Shizuku.pingBinder()
    } catch (e: Throwable) {
        false
    }

    fun shizukuGranted(): Boolean = try {
        shizukuRunning() && !Shizuku.isPreV11() &&
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
    } catch (e: Throwable) {
        false
    }

    fun requestShizuku(activity: Activity): Boolean {
        if (!shizukuRunning()) return false
        if (shizukuGranted()) return true
        return try {
            Shizuku.requestPermission(REQUEST_SHIZUKU)
            true
        } catch (e: Throwable) {
            false
        }
    }

    fun openShizuku(context: Context): Boolean {
        return try {
            val intent = context.packageManager
                .getLaunchIntentForPackage("moe.shizuku.privileged.api")
            if (intent == null) return false
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Throwable) {
            false
        }
    }

    /** Which channel is usable right now; the strongest one wins. */
    fun bestChannel(): String {
        if (rootAvailable()) return "root"
        if (shizukuGranted()) return "shizuku"
        return "none"
    }

    fun capabilities(context: Context): Map<String, Any> {
        val map = HashMap<String, Any>()
        map["root"] = rootAvailable()
        map["shizuku"] = shizukuRunning()
        map["shizukuGranted"] = shizukuGranted()
        map["channel"] = bestChannel()
        map["sdk"] = Build.VERSION.SDK_INT
        map["model"] = "${Build.MANUFACTURER} ${Build.MODEL}"
        map["notifications"] = notificationsAllowed(context)
        map["writeSettings"] = if (Build.VERSION.SDK_INT >= 23) {
            Settings.System.canWrite(context)
        } else {
            false
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        map["dndAccess"] = if (Build.VERSION.SDK_INT >= 23) {
            nm.isNotificationPolicyAccessGranted
        } else {
            false
        }
        map["powerSave"] = (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .isPowerSaveMode
        return map
    }

    // ------------------------------------------------------------------- shell

    /**
     * Runs a command through [mode] (`auto` / `root` / `shizuku`). `auto` picks
     * root first, then Shizuku, then gives up so the caller can fall back to the
     * unprivileged shell.
     */
    fun run(mode: String, command: String, timeoutSec: Int): Map<String, Any> {
        val wanted = if (mode.isEmpty() || mode == "auto") bestChannel() else mode
        return when (wanted) {
            "root" -> {
                if (!rootAvailable()) denied("root")
                else runRoot(command, timeoutSec)
            }
            "shizuku" -> {
                if (!shizukuGranted()) denied("shizuku")
                else runShizuku(command, timeoutSec)
            }
            else -> denied("none")
        }
    }

    /** Process.waitFor(timeout) is API 26, and this app supports 21. */
    private fun awaitExit(process: Process, millis: Long): Boolean {
        val deadline = System.currentTimeMillis() + millis
        while (System.currentTimeMillis() < deadline) {
            try {
                process.exitValue()
                return true
            } catch (e: IllegalThreadStateException) {
                Thread.sleep(50)
            }
        }
        return false
    }

    private fun denied(channel: String): Map<String, Any> = hashMapOf(
        "channel" to channel,
        "exit" to 126,
        "stdout" to "",
        "stderr" to when (channel) {
            "root" -> "root 不可用：没有 su，或授权被拒绝。"
            "shizuku" -> "Shizuku 未运行或未授权。打开 Shizuku 授予本应用权限后再试。"
            else -> "没有可用的提权通道。root 或 Shizuku 二者其一即可。"
        }
    )

    private fun runRoot(command: String, timeoutSec: Int): Map<String, Any> {
        val process = try {
            ProcessBuilder("su", "-c", command).redirectErrorStream(false).start()
        } catch (e: Throwable) {
            return denied("root")
        }
        return collect(process, timeoutSec, "root")
    }

    private fun runShizuku(command: String, timeoutSec: Int): Map<String, Any> {
        val process = try {
            // newProcess is what makes Shizuku special: the child runs with the
            // shell uid, so `pm`, `settings`, `input` and `cmd` all work.
            Shizuku.newProcess(arrayOf("sh", "-c", command), null, null)
        } catch (e: Throwable) {
            return denied("shizuku")
        }
        return collect(process, timeoutSec, "shizuku")
    }

    private fun collect(process: Process, timeoutSec: Int, channel: String): Map<String, Any> {
        val out = StringBuilder()
        val err = StringBuilder()
        val t1 = Thread {
            try {
                process.inputStream.bufferedReader().use { r ->
                    r.forEachLine { out.append(it).append('\n') }
                }
            } catch (_: Throwable) {
            }
        }
        val t2 = Thread {
            try {
                process.errorStream.bufferedReader().use { r ->
                    r.forEachLine { err.append(it).append('\n') }
                }
            } catch (_: Throwable) {
            }
        }
        t1.isDaemon = true
        t2.isDaemon = true
        t1.start()
        t2.start()

        val seconds = if (timeoutSec <= 0) 30 else timeoutSec
        val deadline = System.currentTimeMillis() + seconds * 1000L
        var code = -1
        while (System.currentTimeMillis() < deadline) {
            try {
                code = process.exitValue()
                break
            } catch (e: IllegalThreadStateException) {
                Thread.sleep(40)
            }
        }
        if (code == -1) {
            try {
                process.destroy()
                if (Build.VERSION.SDK_INT >= 26) process.destroyForcibly()
            } catch (_: Throwable) {
            }
            t1.join(800)
            t2.join(800)
            return hashMapOf(
                "channel" to channel,
                "exit" to -1,
                "stdout" to out.toString(),
                "stderr" to "超时 ${seconds}s 后被终止"
            )
        }
        t1.join(1200)
        t2.join(1200)
        return hashMapOf(
            "channel" to channel,
            "exit" to code,
            "stdout" to out.toString(),
            "stderr" to err.toString()
        )
    }

    // ------------------------------------------------------- ordinary abilities

    fun notify(context: Context, id: Int, title: String, body: String): Boolean {
        if (!notificationsAllowed(context)) return false
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "自动化",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            channel.description = "自动化规则执行结果"
            nm.createNotificationChannel(channel)
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val flags = if (Build.VERSION.SDK_INT >= 23) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pi = launch?.let { PendingIntent.getActivity(context, 0, it, flags) }
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title.ifEmpty { "ZCode" })
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        if (pi != null) builder.setContentIntent(pi)
        return try {
            NotificationManagerCompat.from(context).notify(id, builder.build())
            true
        } catch (e: Throwable) {
            false
        }
    }

    fun notificationsAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return ContextCompat.checkSelfPermission(
            context, "android.permission.POST_NOTIFICATIONS"
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun requestNotifications(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        if (notificationsAllowed(activity)) return true
        activity.requestPermissions(
            arrayOf("android.permission.POST_NOTIFICATIONS"), REQUEST_NOTIFICATIONS
        )
        return false
    }

    fun clipboardGet(context: Context): String {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = cm.primaryClip ?: return ""
        if (clip.itemCount == 0) return ""
        return clip.getItemAt(0).coerceToText(context).toString()
    }

    fun clipboardSet(context: Context, text: String): Boolean {
        return try {
            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("ZCode", text))
            true
        } catch (e: Throwable) {
            false
        }
    }

    fun vibrate(context: Context, ms: Int): Boolean {
        val v = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator ?: return false
        if (!v.hasVibrator()) return false
        val millis = if (ms <= 0) 120L else ms.toLong()
        return try {
            if (Build.VERSION.SDK_INT >= 26) {
                v.vibrate(VibrationEffect.createOneShot(millis, VibrationEffect.DEFAULT_AMPLITUDE))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(millis)
            }
            true
        } catch (e: Throwable) {
            false
        }
    }

    fun openApp(context: Context, target: String): Boolean {
        if (target.isEmpty()) return false
        val pm = context.packageManager
        val pkg = if (target.contains(".")) {
            target
        } else {
            (installedApps(context, target).firstOrNull()?.get("package") as? String)
                ?: target
        }
        val intent = pm.getLaunchIntentForPackage(pkg) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (e: Throwable) {
            false
        }
    }

    fun installedApps(context: Context, query: String): List<Map<String, Any>> {
        val pm = context.packageManager
        val list = if (Build.VERSION.SDK_INT >= 33) {
            pm.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getInstalledApplications(0)
        }
        val q = query.trim().lowercase()
        val out = ArrayList<Map<String, Any>>()
        for (info in list) {
            val label = try {
                pm.getApplicationLabel(info).toString()
            } catch (e: Throwable) {
                info.packageName
            }
            if (q.isNotEmpty() &&
                !label.lowercase().contains(q) &&
                !info.packageName.lowercase().contains(q)
            ) continue
            val map = HashMap<String, Any>()
            map["package"] = info.packageName
            map["label"] = label
            map["system"] = (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
            out.add(map)
            if (out.size >= 120) break
        }
        out.sortBy { (it["label"] as String).lowercase() }
        return out
    }

    fun battery(context: Context): Map<String, Any> {
        val map = HashMap<String, Any>()
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        val level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        map["level"] = level
        val intent = context.registerReceiver(
            null, android.content.IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        )
        if (intent != null) {
            val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            map["charging"] =
                status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL
            map["temperature"] = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) / 10.0
            map["voltage"] = intent.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0)
            map["health"] = intent.getIntExtra(BatteryManager.EXTRA_HEALTH, 0)
        }
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        map["screenOn"] = pm.isInteractive
        map["powerSave"] = pm.isPowerSaveMode
        return map
    }

    fun volume(context: Context, stream: String, delta: Int): Map<String, Any> {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val which = when (stream) {
            "alarm" -> AudioManager.STREAM_ALARM
            "ring" -> AudioManager.STREAM_RING
            "music" -> AudioManager.STREAM_MUSIC
            else -> AudioManager.STREAM_MUSIC
        }
        if (delta != 0) {
            val step = if (delta > 0) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER
            repeat(kotlin.math.abs(delta)) {
                am.adjustStreamVolume(which, step, 0)
            }
        }
        val max = am.getStreamMaxVolume(which)
        val now = am.getStreamVolume(which)
        return hashMapOf("stream" to stream, "level" to now, "max" to max)
    }

    /** Opens the screen that lets the user grant a special app access. */
    fun openSpecial(context: Context, kind: String): Boolean {
        val action = when (kind) {
            "write_settings" -> Settings.ACTION_MANAGE_WRITE_SETTINGS
            "dnd" -> Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS
            "notifications" -> Settings.ACTION_APP_NOTIFICATION_SETTINGS
            "battery" -> Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
            "usage" -> Settings.ACTION_USAGE_ACCESS_SETTINGS
            else -> Settings.ACTION_SETTINGS
        }
        return try {
            val intent = Intent(action)
            if (kind == "notifications" || kind == "battery") {
                intent.data = Uri.parse("package:${context.packageName}")
                intent.putExtra("android.provider.extra.APP_PACKAGE", context.packageName)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Throwable) {
            false
        }
    }
}
