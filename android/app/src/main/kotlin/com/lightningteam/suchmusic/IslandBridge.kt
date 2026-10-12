package com.lightningteam.suchmusic

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import org.json.JSONObject

/**
 * 小米灵动岛 / 超级岛增强桥。
 *
 * 设计原则（见 docs/ARCH-二改.md §3.5）：**尽力而为，任何失败静默降级**，
 * 绝不阻断播放。主方案仍走 audio_service 通知副标题，本类只作增强。
 */
class IslandBridge(private val context: Context) {

    companion object {
        private const val TAG = "IslandBridge"

        /** 与方法通道名保持一致 */
        const val CHANNEL = "com.lightningteam.suchmusic/island"
    }

    /**
     * 能力检测：返回 {isMiui, supported, canShowFocus, reason}。
     * 任一环节异常都返回 supported=false + reason，不抛出。
     */
    fun capability(): Map<String, Any> {
        val isMiui = detectMiui()
        val islandFeatureOn = getSystemProperty("persist.sys.feature.island") == "true"
        var canShowFocus = false
        val reason: String

        try {
            when {
                !isMiui -> {
                    reason = "not_miui"
                }
                !islandFeatureOn -> {
                    reason = "island_feature_off"
                }
                else -> {
                    val protocol = Settings.System.getInt(
                        context.contentResolver,
                        "notification_focus_protocol",
                        0
                    )
                    canShowFocus = protocol >= 2
                    reason = if (canShowFocus) "ok" else "protocol_unsupported"
                }
            }
        } catch (e: Exception) {
            canShowFocus = false
            return mapOf(
                "isMiui" to isMiui,
                "supported" to false,
                "canShowFocus" to false,
                "reason" to ("detect_failed:" + e.message)
            )
        }

        return mapOf(
            "isMiui" to isMiui,
            "supported" to (islandFeatureOn && canShowFocus),
            "canShowFocus" to canShowFocus,
            "reason" to reason
        )
    }

    /**
     * 把 miui.focus.param 注入本 App 的媒体通知（audio_service MediaStyle 通知）。
     * 复用原通知 id/tag，避免产生重复通知。
     */
    fun applyFocus(title: String, content: String, islandId: String): Boolean {
        return try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val active = nm.activeNotifications ?: return false
            val pkg = context.packageName
            var applied = false

            for (sbn in active) {
                if (sbn.packageName != pkg) continue
                val builder = Notification.Builder.recoverBuilder(context, sbn.notification)
                val params = JSONObject().apply {
                    put(
                        "param_v2", JSONObject().apply {
                            put("business", "such_music")
                            put("protocol", 2)
                            put("version", 1)
                            put("islandId", islandId)
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
                val extras = Bundle()
                extras.putString("miui.focus.param", params.toString())
                builder.addExtras(extras)
                nm.notify(sbn.tag, sbn.id, builder.build())
                applied = true
            }
            applied
        } catch (e: Exception) {
            Log.w(TAG, "applyFocus failed: " + e.message)
            false
        }
    }

    /** 清除超级岛参数（停止播放 / 关闭开关时调用） */
    fun clearFocus(): Boolean {
        return try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val active = nm.activeNotifications ?: return false
            val pkg = context.packageName
            var cleared = false

            for (sbn in active) {
                if (sbn.packageName != pkg) continue
                val builder = Notification.Builder.recoverBuilder(context, sbn.notification)
                val extras = Bundle()
                extras.putString("miui.focus.param", "{\"param_v2\":null}")
                builder.addExtras(extras)
                nm.notify(sbn.tag, sbn.id, builder.build())
                cleared = true
            }
            cleared
        } catch (e: Exception) {
            Log.w(TAG, "clearFocus failed: " + e.message)
            false
        }
    }

    /** 是否为小米设备（厂商名或 MIUI 版本属性） */
    private fun detectMiui(): Boolean {
        val manufacturer = (Build.MANUFACTURER ?: "").lowercase()
        if (manufacturer.contains("xiaomi") || manufacturer.contains("redmi")) return true
        val miuiVersion = getSystemProperty("ro.miui.ui.version.name")
        return !miuiVersion.isNullOrEmpty()
    }

    /** 反射读取 android.os.SystemProperties.get(key)（部分 ROM 裁剪时返回 null） */
    private fun getSystemProperty(key: String): String? {
        return try {
            val cls = Class.forName("android.os.SystemProperties")
            val get = cls.getMethod("get", String::class.java)
            get.invoke(null, key) as? String
        } catch (e: Exception) {
            null
        }
    }
}
