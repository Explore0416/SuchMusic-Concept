package com.such.music.such_music

import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
    }

    /**
     * 注册小米灵动岛 / 超级岛增强通道（com.such.music/island）。
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
    }
}
