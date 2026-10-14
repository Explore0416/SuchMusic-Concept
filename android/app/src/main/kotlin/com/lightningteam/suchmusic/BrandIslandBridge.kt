package com.lightningteam.suchmusic

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * 多品牌「灵动胶囊 / 小窗」适配桥。
 *
 * 与 [IslandBridge]（只做小米超级岛）不同，本类按厂商分流：
 * - 小米 / Redmi（HyperOS 超级岛）：注入通知 extras `miui.focus.param`
 * - vivo（原子通知 / 原子岛）：注入通知 extras 前缀 `notification.superx.*`
 * - OPPO / OnePlus / realme（ColorOS 16 流体云）：已完整接入 Android 16 原生
 *   Live Updates，**不接私有 API**，仅走标准通知内容
 * - 荣耀 / 华为 / 其他：无三方公开接口，走原生兜底（标准 MediaStyle 通知 +
 *   通知副标题展示歌词，见 `notification_lyric_service`）
 *
 * 全部逻辑 try/catch 兜底：失败返回 false，绝不抛异常、绝不阻断播放。
 *
 * 接入方式（MainActivity.configureFlutterEngine 内一行）：
 * ```
 * flutterEngine.plugins.add(BrandIslandBridge())
 * ```
 */
class BrandIslandBridge : FlutterPlugin, MethodChannel.MethodCallHandler {

    companion object {
        /** 与 Dart 侧 BrandIslandService 的通道名保持一致 */
        const val CHANNEL = "com.lightningteam.suchmusic/brand_island"

        private const val TAG = "BrandIslandBridge"

        // ---- 品牌标识 ----
        private const val BRAND_XIAOMI = "xiaomi"
        private const val BRAND_VIVO = "vivo"
        private const val BRAND_HONOR = "honor"
        private const val BRAND_OPPO = "oppo"
        private const val BRAND_HUAWEI = "huawei"
        private const val BRAND_GENERIC = "generic"

        // ---- 注入策略 ----
        private const val STRATEGY_MIUI = "miui_focus_param"
        private const val STRATEGY_VIVO = "vivo_superx"
        private const val STRATEGY_NATIVE = "native_live_updates"
        private const val STRATEGY_FALLBACK = "fallback"

        // ---- vivo 原子通知 / 原子岛 触点位掩码 ----
        private const val DISPLAY_NOTIFICATION = 0x001 // 通知
        private const val DISPLAY_LOCKSCREEN = 0x010 // 锁屏
        private const val DISPLAY_STATUS_BAR = 0x100 // 状态栏胶囊
        private const val DISPLAY_ALL =
            DISPLAY_NOTIFICATION or DISPLAY_LOCKSCREEN or DISPLAY_STATUS_BAR

        /** vivo superx.operation：0 创建 / 1 更新 / 2 结束 */
        private const val OP_UPDATE = 1
        private const val OP_END = 2

        /** 胶囊文本/背景色传 -1：交由系统按主题取默认配色，避免误设成黑色 */
        private const val COLOR_UNSPECIFIED = -1

        /**
         * ColorOS 16 = Android 16（API 36），其流体云已完整接入原生
         * Live Updates，低于该版本不声明支持。
         */
        private const val SDK_ANDROID_16 = 36
    }

    private lateinit var appContext: Context
    private var channel: MethodChannel? = null

    // region FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val c = MethodChannel(binding.binaryMessenger, CHANNEL)
        c.setMethodCallHandler(this)
        channel = c
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capability" -> result.success(capability())
            "applyFocus" -> {
                val title = call.argument<String>("title") ?: ""
                val content = call.argument<String>("content") ?: ""
                result.success(applyFocus(title, content))
            }
            "clearFocus" -> result.success(clearFocus())
            else -> result.notImplemented()
        }
    }

    // endregion

    /**
     * 能力检测：返回 {brand, supported, strategy, reason}。
     * 任何异常都降级为 supported=false，不抛出。
     */
    fun capability(): Map<String, Any?> {
        return try {
            val brand = detectBrand()
            when (brand) {
                BRAND_XIAOMI -> mapOf(
                    "brand" to brand,
                    "supported" to true,
                    "strategy" to STRATEGY_MIUI,
                    "reason" to "ok"
                )

                BRAND_VIVO -> mapOf(
                    "brand" to brand,
                    "supported" to true,
                    "strategy" to STRATEGY_VIVO,
                    "reason" to "ok"
                )

                BRAND_OPPO -> {
                    val ok = Build.VERSION.SDK_INT >= SDK_ANDROID_16
                    mapOf(
                        "brand" to brand,
                        "supported" to ok,
                        "strategy" to STRATEGY_NATIVE,
                        "reason" to if (ok) "ok" else "os_version_too_low"
                    )
                }

                BRAND_HONOR, BRAND_HUAWEI -> mapOf(
                    "brand" to brand,
                    "supported" to false,
                    "strategy" to STRATEGY_FALLBACK,
                    "reason" to "no_public_api"
                )

                else -> mapOf(
                    "brand" to BRAND_GENERIC,
                    "supported" to false,
                    "strategy" to STRATEGY_FALLBACK,
                    "reason" to "generic_device"
                )
            }
        } catch (e: Throwable) {
            Log.w(TAG, "capability failed: " + e.message)
            mapOf(
                "brand" to BRAND_GENERIC,
                "supported" to false,
                "strategy" to STRATEGY_FALLBACK,
                "reason" to ("detect_failed:" + e.message)
            )
        }
    }

    /**
     * 把当前曲目 / 歌词写入本 App 的媒体通知（audio_service MediaStyle 通知）：
     * 统一刷新标准内容，再按品牌注入私有 extras；无私有接口的品牌只走标准内容。
     *
     * 复用原通知的 tag/id，避免产生重复通知。
     */
    fun applyFocus(title: String, content: String): Boolean {
        if (!::appContext.isInitialized) return false
        return try {
            val nm =
                appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val active = nm.activeNotifications ?: return false
            val pkg = appContext.packageName
            val brand = detectBrand()
            var applied = false

            for (sbn in active) {
                if (sbn.packageName != pkg) continue
                val builder = Notification.Builder.recoverBuilder(appContext, sbn.notification)
                // 标准内容兜底：所有品牌都刷新（荣耀 / 华为 / 通用设备仅此生效）
                if (title.isNotEmpty()) builder.setContentTitle(title)
                if (content.isNotEmpty()) builder.setContentText(content)

                when (brand) {
                    BRAND_VIVO -> addVivoCapsule(builder, content, OP_UPDATE)
                    BRAND_XIAOMI -> addMiuiFocus(builder, title, content)
                    else -> Unit // OPPO / 荣耀 / 华为 / 通用：不注入任何私有字段
                }

                nm.notify(sbn.tag, sbn.id, builder.build())
                applied = true
            }
            applied
        } catch (e: Throwable) {
            Log.w(TAG, "applyFocus failed: " + e.message)
            false
        }
    }

    /** 清除胶囊 / 小窗展示（停止播放或关闭开关时调用）。 */
    fun clearFocus(): Boolean {
        if (!::appContext.isInitialized) return false
        return try {
            val nm =
                appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val active = nm.activeNotifications ?: return false
            val pkg = appContext.packageName
            val brand = detectBrand()
            var cleared = false

            for (sbn in active) {
                if (sbn.packageName != pkg) continue
                val builder = Notification.Builder.recoverBuilder(appContext, sbn.notification)
                when (brand) {
                    BRAND_VIVO -> addVivoCapsule(builder, "", OP_END)
                    BRAND_XIAOMI -> builder.addExtras(
                        Bundle().apply { putString("miui.focus.param", "{\"param_v2\":null}") }
                    )

                    else -> Unit
                }
                nm.notify(sbn.tag, sbn.id, builder.build())
                cleared = true
            }
            cleared
        } catch (e: Throwable) {
            Log.w(TAG, "clearFocus failed: " + e.message)
            false
        }
    }

    // region 品牌私有 extras

    /**
     * vivo 原子通知 / 原子岛：`notification.superx.*`。
     * [operation] 为 0 创建 / 1 更新 / 2 结束；结束时 state 置 0。
     */
    private fun addVivoCapsule(builder: Notification.Builder, content: String, operation: Int) {
        val ending = operation == OP_END
        val extras = Bundle().apply {
            putInt("notification.superx.capsule.state", if (ending) 0 else 1)
            putString("notification.superx.capsule.content", content)
            putInt("notification.superx.capsule.contentColor", COLOR_UNSPECIFIED)
            putInt("notification.superx.capsule.bgColor", COLOR_UNSPECIFIED)
            putLong("notification.superx.capsule.showTime", System.currentTimeMillis())
            putInt("notification.superx.capsule.clickResp", 1) // 点击胶囊回落到通知内容
            putInt("superx.displays", DISPLAY_ALL)
            putInt("superx.operation", operation)
        }
        builder.addExtras(extras)
    }

    /** 小米 HyperOS 超级岛：`miui.focus.param`（与 IslandBridge 同协议 v2）。 */
    private fun addMiuiFocus(builder: Notification.Builder, title: String, content: String) {
        val params = JSONObject().apply {
            put(
                "param_v2", JSONObject().apply {
                    put("business", "such_music")
                    put("protocol", 2)
                    put("version", 1)
                    put("islandId", "such_music_lyric")
                    put("title", title)
                    put("content", content)
                    put(
                        "islandProperty", JSONObject().apply {
                            put("islandTitle", title)
                            put("islandContent", content)
                        }
                    )
                }
            )
        }
        builder.addExtras(Bundle().apply { putString("miui.focus.param", params.toString()) })
    }

    // endregion

    /** 厂商识别：MANUFACTURER / BRAND 小写匹配，未命中归为 generic。 */
    private fun detectBrand(): String {
        val manufacturer = (Build.MANUFACTURER ?: "").lowercase()
        val brand = (Build.BRAND ?: "").lowercase()
        val all = "$manufacturer $brand"
        return when {
            all.contains("xiaomi") || all.contains("redmi") -> BRAND_XIAOMI
            all.contains("vivo") -> BRAND_VIVO
            all.contains("honor") || all.contains("magic") -> BRAND_HONOR
            all.contains("oppo") || all.contains("oneplus") || all.contains("realme") -> BRAND_OPPO
            all.contains("huawei") -> BRAND_HUAWEI
            else -> BRAND_GENERIC
        }
    }
}
