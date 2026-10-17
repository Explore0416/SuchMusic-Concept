package com.lightningteam.suchmusic

import android.content.ContentResolver
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.WindowManager
import com.lightningteam.suchmusic.band.BandChannelBridge
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    companion object {
        /** 入站音频事件通道：系统在「打开方式」/分享中呼起本 App 时，把音频 Uri 送给 Flutter。 */
        const val INBOUND_AUDIO_CHANNEL = "com.lightningteam.suchmusic/inbound_audio"
    }

    /** 尚未送达 Flutter 的入站音频（Flutter 侧监听通道后再投递）。 */
    private var pendingAudioUri: String? = null
    private var pendingAudioName: String? = null
    private var audioSink: EventChannel.EventSink? = null

    /**
     * 音效桥：**提升为实例字段**（而非 configureFlutterEngine 内的局部变量）。
     * 音效需要跨多次 MethodChannel 调用保持状态——`desiredCode`（用户期望的预设）
     * 与当前音频会话 ID——因此不能每次调用都重建。
     */
    private val soundFx: SoundEffectBridge by lazy { SoundEffectBridge(applicationContext) }

    /**
     * 手环桥：同样**提升为实例字段**长期持有（连接、监听、路由状态需跨调用保持）。
     * 没有官方 `xms-wearable-lib` AAR 时内部回退 Noop 适配器，通道仍可正常应答。
     */
    private val bandBridge: BandChannelBridge by lazy { BandChannelBridge(applicationContext) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+ 需运行时授予通知权限：手环 SDK 的「设备互联授权」以系统通知呈现，
        // 未授权时用户看不到任何提示 → 权限永远无法授予 → 互联一直「连接中」。
        ensureNotificationPermission()
        // 原生兜底：窗口系统栏全透明。release 下 Flutter SystemChrome 的
        // 导航栏透明设置不可靠（debug 正常、release 白底），故在此强制设置
        window.apply {
            addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
            statusBarColor = Color.TRANSPARENT
            navigationBarColor = Color.TRANSPARENT
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
        captureInboundAudio(intent)
    }

    /** 已在前台时再次被呼起（singleTop）→ 复用实例，走 onNewIntent。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureInboundAudio(intent)
    }

    /**
     * 解析入站音频意图：`ACTION_VIEW`（打开方式）取 `data`，
     * `ACTION_SEND`（分享）取 `EXTRA_STREAM`；命中则缓存 Uri + 显示名并尝试投递。
     */
    /** Android 13+：请求通知权限（手环授权提示与播放通知都依赖它）。 */
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33) {
            val granted = checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!granted) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
            }
        }
    }

    private fun captureInboundAudio(intent: Intent?) {
        val i = intent ?: return
        val action = i.action ?: return
        if (action != Intent.ACTION_VIEW && action != Intent.ACTION_SEND) return

        val uri: Uri? = if (action == Intent.ACTION_SEND) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION") i.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
            }
        } else {
            i.data
        }
        if (uri == null) return

        // 尽可能让后台播放服务也能长期读取该 Uri（部分 ROM 不支持则静默忽略）
        try {
            val takeFlags = i.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
            contentResolver.takePersistableUriPermission(uri, takeFlags)
        } catch (_: Exception) {
        }

        pendingAudioUri = uri.toString()
        pendingAudioName = resolveDisplayName(uri)
        emitPendingAudio()
    }

    /** content Uri 查 DISPLAY_NAME，file Uri 取末段文件名；失败退回 null。 */
    private fun resolveDisplayName(uri: Uri): String? {
        return try {
            if (uri.scheme == ContentResolver.SCHEME_CONTENT) {
                contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
                }
            } else {
                uri.lastPathSegment
            }
        } catch (_: Exception) {
            uri.lastPathSegment
        }
    }

    /** 通道已监听则立即投递缓存的入站音频。 */
    private fun emitPendingAudio() {
        val sink = audioSink ?: return
        val uri = pendingAudioUri ?: return
        sink.success(mapOf("uri" to uri, "name" to (pendingAudioName ?: "")))
        pendingAudioUri = null
        pendingAudioName = null
    }

    /**
     * 注册小米灵动岛 / 超级岛增强通道（com.lightningteam.suchmusic/island）。
     *
     * 注意：继承自 AudioServiceActivity（即 FlutterActivity），可覆写
     * configureFlutterEngine；此方法在 Activity 生命周期内可能被多次调用
     * （如引擎缓存失效重建），每次都必须重新注册 setMethodCallHandler。
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = IslandBridge(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IslandBridge.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capability" -> {
                        try {
                            result.success(bridge.capability())
                        } catch (e: Exception) {
                            result.success(
                                mapOf(
                                    "isMiui" to false,
                                    "supported" to false,
                                    "canShowFocus" to false,
                                    "reason" to ("error:" + e.message)
                                )
                            )
                        }
                    }
                    "applyFocus" -> {
                        val title = call.argument<String>("title") ?: ""
                        val content = call.argument<String>("content") ?: ""
                        val islandId =
                            call.argument<String>("islandId") ?: "such_music_lyric"
                        try {
                            result.success(bridge.applyFocus(title, content, islandId))
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "clearFocus" -> {
                        try {
                            result.success(bridge.clearFocus())
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 音效（DynamicsProcessing 均衡器 / 预设）——绑定 App 自己的播放会话
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SoundEffectBridge.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "available" -> result.success(soundFx.available())
                    "presets" -> result.success(soundFx.listPresets())
                    "apply" -> {
                        val code = call.argument<String>("code") ?: "off"
                        val sessionId = call.argument<Int>("sessionId") ?: 0
                        result.success(soundFx.apply(code, sessionId))
                    }
                    "setSessionId" -> {
                        val id = call.argument<Int>("id") ?: 0
                        result.success(soundFx.setSessionId(id))
                    }
                    "diagnose" -> result.success(soundFx.diagnose())
                    "disable" -> result.success(soundFx.disable())
                    "current" -> result.success(soundFx.current())
                    else -> result.notImplemented()
                }
            }

        // 手环桥接（小米手环）：MethodChannel + EventChannel，SDK 调用经薄适配层反射访问
        bandBridge.register(flutterEngine)

        // 多品牌灵动胶囊 / 小窗增强（小米 / vivo / OPPO / 荣耀 / 通用兜底）
        flutterEngine.plugins.add(BrandIslandBridge())

        // 入站音频：Flutter 侧监听后投递「打开方式 / 分享」带来的本地音频
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, INBOUND_AUDIO_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    audioSink = events
                    emitPendingAudio()
                }

                override fun onCancel(arguments: Any?) {
                    audioSink = null
                }
            })
    }
}
