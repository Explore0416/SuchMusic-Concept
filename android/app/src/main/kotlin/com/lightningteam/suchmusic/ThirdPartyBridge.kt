package com.lightningteam.suchmusic

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.security.MessageDigest

/**
 * 第三方授权原生桥（ARCHITECTURE §8.2）。
 *
 * 只做三件事，**不含任何授权决策**（决策全在 Dart 侧 ThirdPartyAuthService）：
 * 1. `getInstalledAppInfo`：查包是否安装 + 应用名 + 签名 SHA-256（信任根，T1）；
 * 2. `sendClientCallback`：用 explicit intent（setPackage）把 code 投给目标包（T2）；
 * 3. `getLaunchUri`：把冷启动深链交给 Flutter；
 * 4. `getAppIcon`：取目标应用图标 PNG 字节（确认页展示真实图标，T10）；
 * 5. `showAccessNotice`：静默续期后发一条系统通知（M6，ARCH §6.6）。
 *
 * 另外通过 EventChannel 把 `onNewIntent` 收到的 `suchmusic://` 推给 Flutter。
 */
class ThirdPartyBridge(private val context: Context) {

    companion object {
        private const val TAG = "ThirdPartyBridge"

        /** 方法通道名（与 Dart 侧 MethodChannelThirdPartyBridge.channelName 一致）。 */
        const val CHANNEL = "com.lightningteam.suchmusic/third_party"

        /** 深链事件通道名（与 Dart 侧 eventsChannelName 一致）。 */
        const val EVENTS_CHANNEL = "com.lightningteam.suchmusic/third_party_events"

        /** 第三方接收授权结果的动作（第三方需声明一个 exported Activity 处理它）。 */
        const val CLIENT_CALLBACK_ACTION = "com.lightningteam.suchmusic.CLIENT_CALLBACK"

        /** 本 App 的自定义 scheme。 */
        const val SCHEME = "suchmusic"

        /** 第三方静默访问通知通道（与 Dart 侧注释保持一致）。 */
        const val ACCESS_CHANNEL_ID = "third_party_access"

        /** 通知通道名（系统设置里展示给用户）。 */
        private const val ACCESS_CHANNEL_NAME = "第三方应用访问"

        /** 访问通知固定 id（同类提醒只保留最新一条，避免堆积）。 */
        private const val ACCESS_NOTICE_ID = 2001

        /** 访问通知的 PendingIntent 请求码。 */
        private const val ACCESS_NOTICE_REQUEST_CODE = 2002

        /**
         * 若 [intent] 携带 `suchmusic://` 数据则返回其字符串，否则 null。
         * 只认 scheme，具体路径交给 Dart 侧判定，避免原生重复一套协议解析。
         */
        fun suchMusicUri(intent: Intent?): String? {
            val data = intent?.data ?: return null
            return if (data.scheme == SCHEME) data.toString() else null
        }
    }

    /** 已监听的 EventChannel sink（Flutter 侧 onListen 之后才有值）。 */
    private var eventSink: EventChannel.EventSink? = null

    /** Flutter 侧还没监听时缓存的深链，监听后立即补发。 */
    private var pendingDeepLink: String? = null

    /** 冷启动 intent 里的深链（`getLaunchUri` 用）。 */
    private var launchUri: String? = null

    // ── 通道注册 ────────────────────────────────────────────────

    /** 注册 MethodChannel + EventChannel；引擎重建时会被再次调用。 */
    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledAppInfo" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        try {
                            result.success(installedAppInfo(pkg))
                        } catch (e: Throwable) {
                            Log.w(TAG, "getInstalledAppInfo 失败: ${e.message}")
                            result.success(notInstalled())
                        }
                    }
                    "sendClientCallback" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        val extras = call.argument<Map<String, Any?>>("extras") ?: emptyMap()
                        try {
                            result.success(sendClientCallback(pkg, extras))
                        } catch (e: Throwable) {
                            Log.w(TAG, "sendClientCallback 失败: ${e.message}")
                            result.success(mapOf("sent" to false, "reason" to "error"))
                        }
                    }
                    "getLaunchUri" -> result.success(mapOf("uri" to (launchUri ?: "")))
                    "getAppIcon" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        try {
                            result.success(appIcon(pkg))
                        } catch (e: Throwable) {
                            Log.w(TAG, "getAppIcon 失败: ${e.message}")
                            result.success(null)
                        }
                    }
                    "showAccessNotice" -> {
                        val title = call.argument<String>("title") ?: ""
                        val content = call.argument<String>("content") ?: ""
                        try {
                            showAccessNotice(title, content)
                            result.success(true)
                        } catch (e: Throwable) {
                            Log.w(TAG, "showAccessNotice 失败: ${e.message}")
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    flushPending()
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    /** 记录冷启动 intent（MainActivity.onCreate 调用；只记录不推送，避免重复处理）。 */
    fun setLaunchIntent(intent: Intent?) {
        launchUri = suchMusicUri(intent)
    }

    /** 推送一条深链（MainActivity.onNewIntent 调用）；Flutter 未监听时先缓存。 */
    fun emitDeepLink(uri: String) {
        pendingDeepLink = uri
        flushPending()
    }

    private fun flushPending() {
        val sink = eventSink ?: return
        val uri = pendingDeepLink ?: return
        sink.success(uri)
        pendingDeepLink = null
    }

    // ── getInstalledAppInfo ────────────────────────────────────

    private fun notInstalled(): Map<String, Any?> = mapOf(
        "installed" to false,
        "label" to "",
        "signatureSha256" to "",
        "versionName" to "",
    )

    /**
     * 返回 `{installed, label, signatureSha256, versionName}`。
     *
     * 签名取法：API 28+ 用 `GET_SIGNING_CERTIFICATES`（多签名时取第一个并告警），
     * 更早版本回退到已废弃的 `GET_SIGNATURES`。
     */
    private fun installedAppInfo(pkg: String): Map<String, Any?> {
        if (pkg.isEmpty()) return notInstalled()
        val pm = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        val info = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(flags.toLong()))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, flags)
            }
        } catch (e: Throwable) {
            // NameNotFoundException 及权限异常一律按「未安装」处理
            return notInstalled()
        }

        val signatures = signaturesOf(info) ?: return notInstalled()
        if (signatures.isEmpty()) return notInstalled()

        val label = try {
            val appInfo = info.applicationInfo
            if (appInfo != null) pm.getApplicationLabel(appInfo).toString() else ""
        } catch (e: Throwable) {
            ""
        }

        return mapOf(
            "installed" to true,
            "label" to label,
            "signatureSha256" to sha256Hex(signatures.first().toByteArray()),
            "versionName" to (info.versionName ?: ""),
        )
    }

    @Suppress("DEPRECATION")
    private fun signaturesOf(info: android.content.pm.PackageInfo): Array<Signature>? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo
            if (signingInfo != null) {
                if (signingInfo.hasMultipleSigners()) {
                    Log.w(TAG, "目标包为多签名，取第一个证书做比对")
                    return signingInfo.apkContentsSigners
                }
                return signingInfo.signingCertificateHistory
            }
        }
        return info.signatures
    }

    /**
     * 取目标应用图标，压成 96×96 PNG 字节返回（Flutter 侧 Image.memory 直接可用）。
     *
     * 取不到（未安装 / 自适应图标异常）时返回 null，Dart 侧退回首字占位。
     */
    private fun appIcon(pkg: String): ByteArray? {
        if (pkg.isEmpty()) return null
        return try {
            val drawable = context.packageManager.getApplicationIcon(pkg)
            val side = 96
            val bitmap = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, side, side)
            drawable.draw(canvas)
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            out.toByteArray()
        } catch (e: Throwable) {
            Log.w(TAG, "读取应用图标失败: ${e.message}")
            null
        }
    }

    /** SHA-256 → 小写 hex（与 Dart 侧注册表格式一致）。 */
    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        val builder = StringBuilder(digest.size * 2)
        for (byte in digest) {
            val v = byte.toInt() and 0xFF
            if (v < 0x10) builder.append('0')
            builder.append(Integer.toHexString(v))
        }
        return builder.toString()
    }

    // ── sendClientCallback ─────────────────────────────────────

    /**
     * 用 explicit intent 把 extras 投给目标包（T2：不走 scheme 回跳）。
     *
     * 目标包没有可处理该 action 的 Activity 时返回
     * `{sent:false, reason:"no_callback_activity"}`，Dart 侧据此回滚授权记录。
     */
    private fun sendClientCallback(
        pkg: String,
        extras: Map<String, Any?>,
    ): Map<String, Any?> {
        if (pkg.isEmpty()) {
            return mapOf("sent" to false, "reason" to "no_callback_activity")
        }
        val intent = Intent(CLIENT_CALLBACK_ACTION).setPackage(pkg)
        // 从非 Activity 上下文（如后台服务）调用时也需 NEW_TASK
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        for ((key, value) in extras) {
            when (value) {
                null -> Unit
                is String -> intent.putExtra(key, value)
                is Int -> intent.putExtra(key, value)
                is Long -> intent.putExtra(key, value)
                is Boolean -> intent.putExtra(key, value)
                is Double -> intent.putExtra(key, value)
                is List<*> -> intent.putStringArrayListExtra(
                    key,
                    ArrayList(value.map { it?.toString() ?: "" }),
                )
                else -> intent.putExtra(key, value.toString())
            }
        }

        val resolved = try {
            context.packageManager.resolveActivity(intent, 0)
        } catch (e: Throwable) {
            null
        }
        if (resolved == null) {
            // Android 11+ 包可见性可能导致 resolve 为 null，但显式包名 intent 仍可能发送成功
            return try {
                context.startActivity(intent)
                mapOf("sent" to true)
            } catch (e: Throwable) {
                mapOf("sent" to false, "reason" to "no_callback_activity")
            }
        }
        return try {
            context.startActivity(intent)
            mapOf("sent" to true)
        } catch (e: Throwable) {
            Log.w(TAG, "投递授权结果失败: ${e.message}")
            mapOf("sent" to false, "reason" to "no_callback_activity")
        }
    }

    // ── showAccessNotice ──────────────────────────────────────

    /**
     * 静默续期后的系统通知（ARCH §6.6 / M6）。
     *
     * 通道 `third_party_access`、重要性 `IMPORTANCE_DEFAULT`（会响一声但不弹全屏），
     * 点击用 [PendingIntent] 拉起 [MainActivity]。通知内容只描述「哪个应用读了什么」，
     * 不含任何数据本体（T8）。
     */
    private fun showAccessNotice(title: String, content: String) {
        if (title.isEmpty() && content.isEmpty()) return
        val manager =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (manager.getNotificationChannel(ACCESS_CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    ACCESS_CHANNEL_ID,
                    ACCESS_CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "第三方应用读取 SuchMusic 数据时的提醒"
                }
                manager.createNotificationChannel(channel)
            }
        }

        // 点击通知回到本 App（singleTop：已在栈顶时走 onNewIntent）
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            ACCESS_NOTICE_REQUEST_CODE,
            launch,
            pendingFlags,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, ACCESS_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(content)
            .setStyle(Notification.BigTextStyle().bigText(content))
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        manager.notify(ACCESS_NOTICE_ID, notification)
    }
}
