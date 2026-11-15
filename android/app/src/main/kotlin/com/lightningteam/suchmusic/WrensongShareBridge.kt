package com.lightningteam.suchmusic

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import org.json.JSONObject

/**
 * 「把歌曲分享给 Wrensong」原生桥（协议见 `docs/wrensong-share.md`）。
 *
 * 只做三件事，**不做任何字段合法性决策**（标题/描述截断、type 选择都在 Dart 侧
 * `WrensongShareService`）：
 * 1. `isInstalled`：查 `top.lztech.wrensong` 是否安装（Android 11+ 需 Manifest
 *    `<queries>` 声明才查得到）；
 * 2. `share`：把 payload 序列化成 JSON、压缩封面、用 explicit intent
 *    （`setPackage`）拉起对方面板；
 * 3. 顺手清理自己写过期封面缓存。
 *
 * 为什么强调 `setPackage`：Wrensong 的 `ACTION_SHARE` 是**私有约定动作**，
 * 不加包名约束时系统会弹出「选择应用」列表，用户可能选到别的 App；
 * 而且对未安装的设备只能靠 `resolveActivity == null` 判定——加了包名才可靠。
 */
class WrensongShareBridge(private val context: Context) {

    companion object {
        private const val TAG = "WrensongShareBridge"

        /** 方法通道名（与 Dart 侧 `MethodChannelWrensongShareBridge.channel` 一致）。 */
        const val CHANNEL = "com.lightningteam.suchmusic/wrensong_share"

        /** Wrensong 约定的分享动作。 */
        const val ACTION_SHARE = "top.lztech.wrensong.ACTION_SHARE"

        /** Wrensong 包名（Manifest `<queries>` 必须同步声明）。 */
        const val TARGET_PACKAGE = "top.lztech.wrensong"

        /** payload JSON 总长上限（Wrensong 侧硬限制）。 */
        private const val PAYLOAD_MAX_BYTES = 8 * 1024

        /** 缩略图上限（压缩后仍超则丢弃 thumb）。 */
        private const val THUMB_MAX_BYTES = 64 * 1024

        /** 缩略图长边上限 / 建议下限。 */
        private const val THUMB_MAX_SIDE = 480
        private const val THUMB_MIN_SIDE = 240

        /** 缓存清理：只删自己写的、超过 1 小时的缩略图（Wrensong 会立即拷贝）。 */
        private const val THUMB_PREFIX = "wrensong_thumb_"
        private const val THUMB_RETENTION_MS = 60L * 60L * 1000L
    }

    /** 注册方法通道。Activity 重建时会被再次调用，每次都重设 handler。 */
    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "isInstalled" -> result.success(isInstalled())
                        "share" -> {
                            val appId = call.argument<String>("appId") ?: ""
                            val payload =
                                call.argument<Map<String, Any?>>("payload") ?: emptyMap()
                            val thumbBytes = call.argument<ByteArray>("thumbBytes")
                            result.success(share(appId, payload, thumbBytes))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    // 任何意外都不让通道挂掉：回一个失败结果，Dart 侧会降级为复制
                    Log.w(TAG, "channel error: ${e.message}")
                    result.success(mapOf("ok" to false, "reason" to "error"))
                }
            }
    }

    /** Wrensong 是否已安装。 */
    fun isInstalled(): Boolean {
        return try {
            context.packageManager.getPackageInfo(TARGET_PACKAGE, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        } catch (e: Exception) {
            // 部分 ROM 在包可见性受限时会抛 SecurityException，同样按未安装处理
            Log.w(TAG, "getPackageInfo failed: ${e.message}")
            false
        }
    }

    /**
     * 唤起 Wrensong 分享。
     *
     * 返回 `{ok: true}` 或 `{ok: false, reason: not_installed|security|error}`。
     * 未安装时 `setPackage` 后 `resolveActivity` 为空（**没有回调**），
     * 所以必须在这里同步判定并把结果交回 Dart 侧降级。
     */
    fun share(
        appId: String,
        payload: Map<String, Any?>,
        thumbBytes: ByteArray?,
    ): Map<String, Any> {
        cleanupStaleThumbs()

        val json = JSONObject()
        // thumb 的 content:// URI 要留到最后放进 intent.clipData（精确授权），
        // 所以先在外层持有：payload 因超长裁掉 thumb 时同步清空，避免「授权了
        // 一条已经不在 payload 里的 URI」。
        var thumbUri: String? = null
        try {
            for ((key, value) in payload) {
                if (value != null) json.put(key, value)
            }
            thumbUri = prepareThumbUri(thumbBytes)
            thumbUri?.let { json.put("thumb", it) }
        } catch (e: Exception) {
            Log.w(TAG, "payload build failed: ${e.message}")
            return mapOf("ok" to false, "reason" to "error")
        }

        // 序列化后仍超 8KB：丢掉 thumb 再试一次（正文信息必须保住）
        var serialized = json.toString()
        if (serialized.toByteArray(Charsets.UTF_8).size > PAYLOAD_MAX_BYTES) {
            json.remove("thumb")
            thumbUri = null
            serialized = json.toString()
        }
        if (serialized.toByteArray(Charsets.UTF_8).size > PAYLOAD_MAX_BYTES) {
            Log.w(TAG, "payload still over ${PAYLOAD_MAX_BYTES}B after dropping thumb")
            return mapOf("ok" to false, "reason" to "payload_too_large")
        }

        val intent = Intent(ACTION_SHARE).apply {
            setPackage(TARGET_PACKAGE)
            addCategory(Intent.CATEGORY_DEFAULT)
            putExtra("app_id", appId)
            putExtra("payload", serialized)
            // 桥持有的是 applicationContext，非 Activity 启动必须带 NEW_TASK，
            // 否则会抛 AndroidRuntimeException 而不是 ActivityNotFound。
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        // 缩略图授权：我们的 FileProvider 是 `android:exported="false"`，
        // **不显式授权对方绝对读不到**（对方 openInputStream 会抛
        // SecurityException，封面静默丢失，而分享本身成功 —— 只看截图/测试
        // 发现不了）。这里只做**精确授权**：
        //  - flag 只对本次 intent 的目标包（setPackage 指定的 Wrensong）生效；
        //  - clipData 只声明这一条 URI，不放开整个 provider 的路径。
        if (thumbUri != null) {
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            intent.clipData = ClipData.newRawUri("thumb", Uri.parse(thumbUri))
        }

        if (resolveTarget(intent) == null) {
            return mapOf("ok" to false, "reason" to "not_installed")
        }

        return try {
            context.startActivity(intent)
            mapOf("ok" to true)
        } catch (e: ActivityNotFoundException) {
            // resolveActivity 通过但 startActivity 仍找不到（包被并发卸载）
            Log.w(TAG, "startActivity ActivityNotFound: ${e.message}")
            mapOf("ok" to false, "reason" to "not_installed")
        } catch (e: SecurityException) {
            Log.w(TAG, "startActivity SecurityException: ${e.message}")
            mapOf("ok" to false, "reason" to "security")
        } catch (e: Exception) {
            Log.w(TAG, "startActivity failed: ${e.message}")
            mapOf("ok" to false, "reason" to "error")
        }
    }

    /** `resolveActivity` 在部分 API 上标注了废弃，但仍是唯一同步判定手段。 */
    @Suppress("DEPRECATION")
    private fun resolveTarget(intent: Intent) = context.packageManager.resolveActivity(intent, 0)

    /**
     * 压缩并落盘封面，返回 FileProvider 的 content:// URI。
     *
     * 尺寸规则：长边 `min(480, max(240, 原长边))`，质量 80；超过 64KB 时依次
     * 降质量（70/60）与缩长边（320/240）重试，仍超则放弃 thumb（返回 null）。
     *
     * 返回值只负责「生成」，**不负责授权**：调用方（[share]）必须把该 URI 放进
     * `intent.clipData` 并加 `FLAG_GRANT_READ_URI_PERMISSION`，否则 exported=false
     * 的 FileProvider 对方读不到。
     */
    private fun prepareThumbUri(bytes: ByteArray?): String? {
        if (bytes == null || bytes.isEmpty()) return null
        return try {
            val source = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
            val jpeg = encodeThumb(source)
            if (jpeg == null) {
                Log.w(TAG, "thumb over ${THUMB_MAX_BYTES}B after all retries, dropped")
                return null
            }

            val file = File(context.cacheDir, "$THUMB_PREFIX${UUID.randomUUID()}.jpg")
            file.writeBytes(jpeg)
            FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileProvider",
                file,
            ).toString()
        } catch (e: Exception) {
            // 缩略图只是锦上添花，失败绝不能拖垮分享主流程
            Log.w(TAG, "thumb prepare failed: ${e.message}")
            null
        }
    }

    /** 长边逐档收缩 + 质量逐档下调，返回第一个 ≤64KB 的 JPEG。 */
    private fun encodeThumb(source: Bitmap): ByteArray? {
        val firstSide =
            min(THUMB_MAX_SIDE, max(THUMB_MIN_SIDE, max(source.width, source.height)))
        val sides = linkedSetOf(firstSide)
        if (320 < firstSide) sides.add(320)
        if (240 < firstSide) sides.add(240)

        for (side in sides) {
            val scaled = scaleToLongSide(source, side)
            for (quality in intArrayOf(80, 70, 60)) {
                val data = compress(scaled, quality)
                if (data != null && data.size <= THUMB_MAX_BYTES) return data
            }
        }
        return null
    }

    /** 等比缩放到指定长边（已小于目标则不放大）。 */
    private fun scaleToLongSide(source: Bitmap, targetLongSide: Int): Bitmap {
        val srcLong = max(source.width, source.height)
        if (srcLong <= targetLongSide) return source
        val ratio = targetLongSide.toFloat() / srcLong.toFloat()
        val width = max(1, (source.width * ratio).toInt())
        val height = max(1, (source.height * ratio).toInt())
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    private fun compress(bitmap: Bitmap, quality: Int): ByteArray? {
        return try {
            val out = ByteArrayOutputStream()
            val ok = bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            if (ok) out.toByteArray() else null
        } catch (e: Exception) {
            Log.w(TAG, "compress failed: ${e.message}")
            null
        }
    }

    /** 清理 1 小时前的自建缩略图缓存；失败不影响分享。 */
    private fun cleanupStaleThumbs() {
        try {
            val now = System.currentTimeMillis()
            context.cacheDir
                ?.listFiles { f -> f.name.startsWith(THUMB_PREFIX) && now - f.lastModified() > THUMB_RETENTION_MS }
                ?.forEach { stale -> stale.delete() }
        } catch (e: Exception) {
            Log.w(TAG, "thumb cleanup failed: ${e.message}")
        }
    }
}
