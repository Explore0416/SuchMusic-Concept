package com.lightningteam.suchmusic.band

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 手环桥接通道（Kotlin ↔ Dart 对接层）。
 *
 * 注册两个通道（与既有 `SoundEffectBridge` / `IslandBridge` 同风格）：
 * - `MethodChannel("com.lightningteam.suchmusic/band")`：可用性、连接、发送、诊断；
 * - `EventChannel("com.lightningteam.suchmusic/band_events")`：把「上行消息 / 状态变化」
 *   推送给 Dart。
 *
 * **关键约束**：所有对外方法都 try/catch 兜底，**绝不把异常抛给 Flutter**；
 * 没有官方 AAR 时 [NoopBandAdapter] 兜底，通道仍可正常应答「SDK 未就绪」。
 *
 * 本类应作为 Activity 的**实例字段**长期持有（与 `SoundEffectBridge` 一致），
 * 以便跨多次调用保持连接与监听状态。
 */
class BandChannelBridge(private val context: Context) {

    companion object {
        private const val TAG = "BandChannelBridge"

        /** Dart 侧 `BandChannel` 使用的通道名，两侧必须一致。 */
        const val CHANNEL = "com.lightningteam.suchmusic/band"
        const val EVENT_CHANNEL = "com.lightningteam.suchmusic/band_events"
    }

    private val main = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    /** 唯一的适配器：有 AAR 且可用时用反射实现，否则用 Noop 兜底。 */
    private val adapter: BandAdapter = createAdapter()

    private val connection: BandConnection
    private val router: BandMessageRouter

    init {
        connection = BandConnection(
            adapter = adapter,
            onStateChanged = { state -> emit(mapOf("type" to "state", "state" to state)) },
            onMessage = { text -> router.onBandMessage(text) },
        )
        router = BandMessageRouter(
            connection = connection,
            onToDart = { json -> emit(mapOf("type" to "message", "json" to json)) },
        )
    }

    private fun createAdapter(): BandAdapter {
        return try {
            val xms = XmsWearableAdapter(context)
            if (xms.isAvailable()) xms else NoopBandAdapter(context)
        } catch (e: Throwable) {
            Log.w(TAG, "创建 Xms 适配器失败，回退 Noop: ${e.message}")
            NoopBandAdapter(context)
        }
    }

    /** 在 configureFlutterEngine 中调用，注册两个通道（每次引擎重建都必须重新注册）。 */
    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "available" -> result.success(adapter.isAvailable())
                        "state" -> result.success(connection.currentState())
                        "start" -> result.success(connection.start())
                        "stop" -> {
                            connection.stop()
                            result.success(true)
                        }
                        "send" -> {
                            val json = call.argument<String>("json") ?: ""
                            result.success(router.send(json))
                        }
                        "wearAppInstalled" -> result.success(connection.wearAppInstallState())
                        "diagnose" -> result.success(connection.diagnose())
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    // 绝不把异常抛给 Flutter：业务性失败返回安全值
                    Log.w(TAG, "方法 ${call.method} 异常: ${e.message}")
                    result.success(null)
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    /** 把事件投递到 Dart（统一切到主线程，符合 EventChannel 约定）。 */
    private fun emit(event: Map<String, Any?>) {
        main.post {
            try {
                eventSink?.success(event)
            } catch (e: Throwable) {
                Log.w(TAG, "emit 失败: ${e.message}")
            }
        }
    }
}
