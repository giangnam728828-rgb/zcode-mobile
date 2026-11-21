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
 */
object EventHub {
    private val main = Handler(Looper.getMainLooper())
    private val pending = ArrayDeque<Map<String, Any>>()

    @Volatile
    private var sink: ((Map<String, Any>) -> Unit)? = null

    fun attach(next: (Map<String, Any>) -> Unit) {
        sink = next
        val replay: List<Map<String, Any>>
        synchronized(pending) {
            replay = pending.toList()
            pending.clear()
        }
        for (event in replay) main.post { runCatching { next(event) } }
    }

    fun detach() {
        sink = null
    }

    fun emit(event: Map<String, Any>) {
        val target = sink
        if (target == null) {
            synchronized(pending) {
                if (pending.size >= 24) pending.removeFirst()
                pending.addLast(event)
            }
            return
        }
        main.post {
            try {
                target(event)
            } catch (e: Throwable) {
            }
        }
    }}
