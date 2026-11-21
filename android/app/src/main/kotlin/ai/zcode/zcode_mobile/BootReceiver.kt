package ai.zcode.zcode_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires after a reboot. Android 10+ blocks background activity starts, so we
 * do not try to launch the UI; we leave a flag and a notification, and the
 * automation rules tagged `boot` run the next time the app comes up. That is
 * honest about the restriction instead of silently failing.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        try {
            // Same file the Flutter plugin uses; "flutter." is its key prefix.
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit()
                .putBoolean("flutter.zcode.flag.boot", true)
                .apply()
        } catch (e: Throwable) {
        }
        Privilege.notify(
            context,
            9001,
            "ZCode",
            "已随开机启动。点开应用即可执行「开机」自动化规则。"
        )
    }
}
