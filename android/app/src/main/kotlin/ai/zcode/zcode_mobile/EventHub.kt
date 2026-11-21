package ai.zcode.zcode_mobile

import android.os.Handler
import android.os.Looper

/**
 * One place where native components hand events to Dart.
 *
 * Screen, power and Wi-Fi events come from [DeviceEvents]; the accessibility
 * service adds foreground apps and screen text; the notification listener adds
 * incoming notifications. All three need the same sink, and the sink can be
 * missing (activity destroyed, Dart not listening yet), so the last few events
 * are buffered instead of dropped.
 *
 * Buffered events expire after half a minute: replaying yesterday's
 * notification or an old screen snapshot would fire a rule for something that
 * is no longer true.
 */
object EventHub {
    private const val MAX_BUFFER = 24
    private const val FRESH_MS = 30_000L

    private val main = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<Pair<Long, Map<String, Any>>>()

    @Volatile
    private var sink: ((Map<String, Any>) -> Unit)? = null

    fun attach(next: (Map<String, Any>) -> Unit) {
        sink = next
        val replay: List<Map<String, Any>>
        val now = System.currentTimeMillis()
        synchronized(pending) {
            replay = pending
                .filter { now - it.first <= FRESH_MS }
                .map { it.second }
            pending.clear()
        }
        for (event in replay) main.post { runCatching { next(event) } }
    }

    fun detach() {
        sink = null
    }

    fun emit(event: Map<String, Any>) {
        val target = sink
        val now = System.currentTimeMillis()
        if (target == null) {
            synchronized(pending) {
                while (pending.isNotEmpty() && now - pending.first().first > FRESH_MS) {
                    pending.removeFirst()
                }
                if (pending.size >= MAX_BUFFER) pending.removeFirst()
                pending.addLast(now to event)
            }
            return
        }
        main.post {
            try {
                target(event)
            } catch (e: Throwable) {
            }
        }
    }
}
