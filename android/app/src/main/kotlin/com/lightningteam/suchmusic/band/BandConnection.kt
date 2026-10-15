package com.lightningteam.suchmusic.band

import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * 手环连接 / 重连状态机（文档 §3.2「手机端」）。
 *
 * ```
 * DISCONNECTED → CONNECTING（发现节点 + 申请权限 + 注册监听）
 *              → READY（收到手环任一上行帧，即认为链路可用；握手语义由 Dart 层处理）
 *              → CONNECTING（发送失败 / 链路断开）
 * CONNECTING   → 失败退避 1s→2s→4s（上限 8s）后重试
 * ```
 *
 * 所有对外方法 try/catch 兜底，**绝不把异常抛给 Flutter**（与既有 SoundEffectBridge 风格一致）。
 */
class BandConnection(
    private val adapter: BandAdapter,
    private val onStateChanged: (String) -> Unit,
    private val onMessage: (String) -> Unit,
) {

    companion object {
        private const val TAG = "BandConnection"

        const val STATE_UNAVAILABLE = "unavailable"
        const val STATE_DISCONNECTED = "disconnected"
        const val STATE_CONNECTING = "connecting"
        const val STATE_READY = "ready"

        /** 重连退避（毫秒）。 */
        private val BACKOFF_MS = longArrayOf(1000, 2000, 4000, 8000)
    }

    private val handler = Handler(Looper.getMainLooper())

    @Volatile
    private var state: String = STATE_DISCONNECTED

    private var running = false
    private var attempt = 0
    private var started = false

    private val poll = object : Runnable {
        override fun run() {
            if (!running) return
            if (tryConnect()) {
                attempt = 0
            } else {
                scheduleRetry()
            }
        }
    }

    /** 当前状态字符串。 */
    fun currentState(): String = state

    /** 启动链路；返回是否成功进入连接流程（SDK 未就绪时为 false）。 */
    fun start(): Boolean {
        return try {
            if (!adapter.isAvailable()) {
                setState(STATE_UNAVAILABLE)
                return false
            }
            if (running) return true
            running = true
            started = false
            attempt = 0
            setState(STATE_CONNECTING)
            handler.post(poll)
            true
        } catch (e: Throwable) {
            Log.w(TAG, "start 异常: ${e.message}")
            false
        }
    }

    /** 停止链路并释放。 */
    fun stop() {
        try {
            running = false
            handler.removeCallbacksAndMessages(null)
            adapter.stop()
            started = false
        } catch (e: Throwable) {
            Log.w(TAG, "stop 异常: ${e.message}")
        } finally {
            setState(if (adapter.isAvailable()) STATE_DISCONNECTED else STATE_UNAVAILABLE)
        }
    }

    /** 发送一帧文本；失败时进入重连。 */
    fun send(text: String): Boolean {
        return try {
            val ok = adapter.send(text.toByteArray(Charsets.UTF_8))
            if (!ok) onLinkDown()
            ok
        } catch (e: Throwable) {
            Log.w(TAG, "send 异常: ${e.message}")
            onLinkDown()
            false
        }
    }

    /** 手环端快应用安装状态：`installed` / `not_installed` / `unknown`。 */
    fun wearAppInstallState(): String = try {
        adapter.wearAppInstallState()
    } catch (e: Throwable) {
        BandAdapterDefaults.STATE_UNKNOWN
    }

    /** 诊断信息透传。 */
    fun diagnose(): Map<String, Any?> = try {
        adapter.diagnose() + mapOf("state" to state, "running" to running, "attempt" to attempt)
    } catch (e: Throwable) {
        mapOf("state" to state, "error" to e.message)
    }

    // ── 内部 ──────────────────────────────────────────────────

    private fun tryConnect(): Boolean {
        return try {
            val ok = adapter.start { text -> handleIncoming(text) }
            if (ok) {
                started = true
                // 链路已建立、正在等待握手帧；状态保持 CONNECTING，
                // 收到任一上行帧后由 handleIncoming 置为 READY。
                if (state != STATE_READY) setState(STATE_CONNECTING)
            }
            ok
        } catch (e: Throwable) {
            Log.w(TAG, "tryConnect 异常: ${e.message}")
            false
        }
    }

    private fun handleIncoming(text: String) {
        try {
            attempt = 0
            if (!started) started = true
            if (state != STATE_READY) setState(STATE_READY)
            onMessage(text)
        } catch (e: Throwable) {
            Log.w(TAG, "handleIncoming 异常: ${e.message}")
        }
    }

    private fun onLinkDown() {
        try {
            if (!running) return
            if (adapter.isAvailable()) {
                setState(STATE_CONNECTING)
                handler.removeCallbacks(poll)
                scheduleRetry()
            } else {
                setState(STATE_UNAVAILABLE)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "onLinkDown 异常: ${e.message}")
        }
    }

    private fun scheduleRetry() {
        val delay = BACKOFF_MS[minOf(attempt, BACKOFF_MS.size - 1)]
        attempt++
        handler.removeCallbacks(poll)
        handler.postDelayed(poll, delay)
    }

    private fun setState(next: String) {
        if (state == next) return
        state = next
        try {
            onStateChanged(next)
        } catch (e: Throwable) {
            Log.w(TAG, "onStateChanged 异常: ${e.message}")
        }
    }
}
