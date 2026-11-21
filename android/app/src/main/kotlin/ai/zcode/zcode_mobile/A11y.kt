package ai.zcode.zcode_mobile

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Accessibility is the "no root required" doorway to the things a phone only
 * lets a human do: read the screen, tap a button by its label, type into the
 * focused field, scroll, and notice which app just came to the front.
 *
 * It is also the only honest way to read notifications on modern Android, so
 * the notification listener lives here too and shares [EventHub].
 */
object A11yState {
    @Volatile
    var service: ZcodeAccessibilityService? = null

    @Volatile
    var lastPackage: String = ""

    @Volatile
    var lastLabel: String = ""

    @Volatile
    var lastAt: Long = 0L

    val connected: Boolean get() = service != null

    /** True when the user switched the service on, even if it is restarting. */
    fun enabled(context: Context): Boolean {
        val raw = try {
            Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            )
        } catch (e: Throwable) {
            null
        } ?: return false
        // Stored entries may use the short or the flattened component name, so
        // match on package + class instead of string equality.
        return raw.split(':').any { entry ->
            entry.contains(context.packageName) && entry.contains("ZcodeAccessibilityService")
        }
    }
}

class ZcodeAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        A11yState.service = this
        EventHub.emit(mapOf("type" to "a11y_connected"))
    }

    override fun onUnbind(intent: Intent?): Boolean {
        A11yState.service = null
        EventHub.emit(mapOf("type" to "a11y_disconnected"))
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        A11yState.service = null
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val e = event ?: return
        when (e.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> onWindowChanged(e)
            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED -> {
                // Only apps that use a custom notification layout land here;
                // the listener service covers the rest.
                val pkg = e.packageName?.toString() ?: ""
                val text = e.text?.joinToString(" ") ?: ""
                if (pkg.isEmpty() || text.isEmpty()) return
                EventHub.emit(
                    mapOf(
                        "type" to "notification",
                        "package" to pkg,
                        "app" to A11yOps.labelOf(this, pkg),
                        "title" to "",
                        "text" to text,
                        "source" to "a11y"
                    )
                )
            }
        }
    }

    private fun onWindowChanged(e: AccessibilityEvent) {
        val pkg = e.packageName?.toString() ?: ""
        if (pkg.isEmpty() || pkg == packageName) return
        val now = System.currentTimeMillis()
        // Window state changes arrive in bursts during transitions; one event
        // per app per two seconds is enough for a trigger.
        if (pkg == A11yState.lastPackage && now - A11yState.lastAt < 2000) return
        A11yState.lastPackage = pkg
        A11yState.lastLabel = A11yOps.labelOf(this, pkg)
        A11yState.lastAt = now
        EventHub.emit(
            mapOf(
                "type" to "app_foreground",
                "package" to pkg,
                "label" to A11yState.lastLabel
            )
        )
        // A snapshot on every window change is what makes "screen shows X"
        // rules possible without polling. Keep it small: 600 characters is
        // plenty for a keyword match and cheap to pass across the bridge.
        val snapshot = A11yOps.snapshot(60, 600)
        val text = "${snapshot["text"] ?: ""}"
        if (text.isNotEmpty()) {
            EventHub.emit(
                mapOf(
                    "type" to "screen",
                    "package" to pkg,
                    "app" to A11yState.lastLabel,
                    "text" to text
                )
            )
        }
    }
}

/** Reading notifications needs its own grant, separate from accessibility. */
class ZcodeNotificationService : NotificationListenerService() {
    companion object {
        @Volatile
        var connected: Boolean = false
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        connected = true
        EventHub.emit(mapOf("type" to "notification_listener", "connected" to true))
    }

    override fun onListenerDisconnected() {
        connected = false
        EventHub.emit(mapOf("type" to "notification_listener", "connected" to false))
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val status = sbn ?: return
        if (status.packageName == packageName) return
        val n = status.notification ?: return
        val extras: Bundle = n.extras ?: return
        val title = extras.getCharSequence("android.title")?.toString()?.trim() ?: ""
        val text = (extras.getCharSequence("android.text")
            ?: extras.getCharSequence("android.bigText"))?.toString()?.trim() ?: ""
        val sub = extras.getCharSequence("android.subText")?.toString()?.trim() ?: ""
        if (title.isEmpty() && text.isEmpty()) return
        EventHub.emit(
            mapOf(
                "type" to "notification",
                "package" to status.packageName,
                "app" to A11yOps.labelOf(this, status.packageName),
                "title" to title,
                "text" to if (text.isEmpty()) sub else text,
                "ongoing" to status.isOngoing,
                "source" to "listener"
            )
        )
    }
}

/**
 * Everything a rule or the agent can ask the accessibility service to do.
 *
 * All of it is node based rather than coordinate based, so it survives a
 * different screen size, a theme change or a keyboard that shifts the layout.
 */
object A11yOps {

    fun status(context: Context): Map<String, Any> = hashMapOf(
        "enabled" to A11yState.enabled(context),
        "connected" to A11yState.connected,
        "notificationListener" to ZcodeNotificationService.connected,
        "foreground" to A11yState.lastPackage,
        "foregroundLabel" to A11yState.lastLabel
    )

    fun openSettings(context: Context, notifications: Boolean): Boolean {
        val action = if (notifications) {
            Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS
        } else {
            Settings.ACTION_ACCESSIBILITY_SETTINGS
        }
        return try {
            val intent = Intent(action)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Throwable) {
            false
        }
    }

    fun labelOf(context: Context, pkg: String): String {
        if (pkg.isEmpty()) return ""
        return try {
            val pm = context.packageManager
            "${pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0))}"
        } catch (e: Throwable) {
            pkg
        }
    }

    private fun nodes(root: AccessibilityNodeInfo?): List<AccessibilityNodeInfo> {
        val out = ArrayList<AccessibilityNodeInfo>()
        if (root == null) return out
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var guard = 0
        while (queue.isNotEmpty() && guard < 1500) {
            val node = queue.removeFirst()
            guard++
            out.add(node)
            for (i in 0 until node.childCount) {
                val child = try {
                    node.getChild(i)
                } catch (e: Throwable) {
                    null
                }
                if (child != null) queue.add(child)
            }
        }
        return out
    }

    private fun root(): AccessibilityNodeInfo? = A11yState.service?.rootInActiveWindow

    /** A short, readable picture of what is on screen right now. */
    fun snapshot(limit: Int = 60, maxChars: Int = 4000): Map<String, Any> {
        val svc = A11yState.service
        val root = svc?.rootInActiveWindow
        if (svc == null || root == null) return hashMapOf(
            "connected" to false,
            "package" to "",
            "text" to "",
            "nodes" to ArrayList<Map<String, Any>>()
        )
        val pkg = root.packageName?.toString() ?: ""
        val out = ArrayList<Map<String, Any>>()
        val seen = HashSet<String>()
        val sb = StringBuilder()
        for (node in nodes(root)) {
            if (out.size >= limit || sb.length >= maxChars) break
            val text = node.text?.toString()?.trim().orEmpty()
            val desc = node.contentDescription?.toString()?.trim().orEmpty()
            if (text.isEmpty() && desc.isEmpty()) continue
            if (!seen.add("$text|$desc")) continue
            val rect = Rect()
            node.getBoundsInScreen(rect)
            out.add(
                hashMapOf(
                    "text" to text,
                    "desc" to desc,
                    "class" to (node.className?.toString() ?: ""),
                    "clickable" to node.isClickable,
                    "editable" to node.isEditable,
                    "bounds" to "${rect.left},${rect.top},${rect.right},${rect.bottom}"
                )
            )
            if (sb.isNotEmpty()) sb.append('\n')
            sb.append(if (text.isNotEmpty()) text else "[$desc]")
        }
        return hashMapOf(
            "connected" to true,
            "package" to pkg,
            "app" to labelOf(svc, pkg),
            "text" to sb.toString(),
            "nodes" to out
        )
    }

    private fun clickable(node: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        var current = node
        var depth = 0
        while (current != null && depth < 8) {
            if (current.isClickable) return current
            current = try {
                current.parent
            } catch (e: Throwable) {
                null
            }
            depth++
        }
        return null
    }

    fun click(
        text: String,
        index: Int = 0,
        byDesc: Boolean = false,
        longPress: Boolean = false
    ): Boolean {
        if (text.isEmpty()) return false
        val root = root() ?: return false
        val needle = text.lowercase()
        val all = nodes(root)
        fun label(node: AccessibilityNodeInfo): String {
            val raw = if (byDesc) node.contentDescription?.toString() else node.text?.toString()
            return raw?.lowercase()?.trim() ?: ""
        }
        var matches = all.filter { label(it) == needle }
        if (matches.isEmpty()) matches = all.filter { label(it).contains(needle) }
        if (matches.isEmpty()) return false
        val target = matches.getOrNull(index.coerceAtLeast(0)) ?: matches.first()
        val hit = clickable(target) ?: return false
        val action = if (longPress) {
            AccessibilityNodeInfo.ACTION_LONG_CLICK
        } else {
            AccessibilityNodeInfo.ACTION_CLICK
        }
        return try {
            hit.performAction(action)
        } catch (e: Throwable) {
            false
        }
    }

    fun setText(text: String, target: String = ""): Boolean {
        val root = root() ?: return false
        val all = nodes(root)
        val hint = target.lowercase()
        val editable = all.filter { it.isEditable }
        val node = editable.firstOrNull { node ->
            hint.isEmpty() || (node.text?.toString()?.lowercase()?.contains(hint) == true) ||
                (node.contentDescription?.toString()?.lowercase()?.contains(hint) == true)
        } ?: editable.firstOrNull() ?: return false
        return try {
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
            val args = Bundle()
            args.putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                text
            )
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        } catch (e: Throwable) {
            false
        }
    }

    fun scroll(forward: Boolean = true, times: Int = 1): Boolean {
        val root = root() ?: return false
        val target = nodes(root).firstOrNull { it.isScrollable } ?: root
        var ok = false
        for (i in 0 until times.coerceIn(1, 6)) {
            val action = if (forward) {
                AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
            } else {
                AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
            }
            ok = try {
                target.performAction(action) || ok
            } catch (e: Throwable) {
                ok
            }
        }
        return ok
    }

    fun global(action: String): Boolean {
        val svc = A11yState.service ?: return false
        val code = when (action) {
            "back" -> AccessibilityService.GLOBAL_ACTION_BACK
            "home" -> AccessibilityService.GLOBAL_ACTION_HOME
            "recents" -> AccessibilityService.GLOBAL_ACTION_RECENTS
            "notifications" -> AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS
            "quick_settings" -> AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS
            "power" -> AccessibilityService.GLOBAL_ACTION_POWER_DIALOG
            "lock" -> if (Build.VERSION.SDK_INT >= 28) {
                AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN
            } else {
                AccessibilityService.GLOBAL_ACTION_HOME
            }
            "screenshot" -> if (Build.VERSION.SDK_INT >= 30) {
                AccessibilityService.GLOBAL_ACTION_TAKE_SCREENSHOT
            } else {
                -1
            }
            else -> -1
        }
        if (code < 0) return false
        return try {
            svc.performGlobalAction(code)
        } catch (e: Throwable) {
            false
        }
    }

    fun tap(x: Int, y: Int): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val svc = A11yState.service ?: return false
        return try {
            val path = Path()
            path.moveTo(x.toFloat(), y.toFloat())
            val stroke = GestureDescription.StrokeDescription(path, 0, 60)
            svc.dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
        } catch (e: Throwable) {
            false
        }
    }

    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, millis: Int): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val svc = A11yState.service ?: return false
        return try {
            val path = Path()
            path.moveTo(x1.toFloat(), y1.toFloat())
            path.lineTo(x2.toFloat(), y2.toFloat())
            val duration = millis.coerceIn(80, 2000)
            val stroke = GestureDescription.StrokeDescription(path, 0, duration.toLong())
            svc.dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
        } catch (e: Throwable) {
            false
        }
    }
}
