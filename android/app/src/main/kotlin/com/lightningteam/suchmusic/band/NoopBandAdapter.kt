package com.lightningteam.suchmusic.band

import android.content.Context

/**
 * 默认兜底适配器：**始终报告「SDK 未就绪」**。
 *
 * 当用户本机没有把官方 `xms-wearable-lib_1.4_release.aar` 放入 `android/app/libs/` 时，
 * [BandChannelBridge] 会选中本实现。它保证：
 * - `flutter analyze` / `flutter test` / `flutter build apk` 全绿（无任何专有依赖）；
 * - UI 能如实展示「SDK 未就绪」，并引导用户按文档放置 AAR 后重新构建。
 *
 * 所有方法只返回安全值，绝不抛异常。
 */
class NoopBandAdapter(@Suppress("UNUSED_PARAMETER") context: Context) : BandAdapter {

    override fun isAvailable(): Boolean = false

    override fun start(listener: BandMessageListener): Boolean = false

    override fun stop() {}

    override fun send(bytes: ByteArray): Boolean = false

    override fun wearAppInstallState(): String = STATE_UNKNOWN

    override fun currentNodeId(): String? = null

    override fun diagnose(): Map<String, Any?> = mapOf(
        "adapter" to "noop",
        "available" to false,
        "reason" to "xms-wearable-lib 未就绪（请将 AAR 放入 android/app/libs/ 后重新构建）",
    )

    companion object {
        const val STATE_UNKNOWN = BandAdapterDefaults.STATE_UNKNOWN
    }
}

/** 适配器共享常量（避免 Noop / Xms 两处硬编码漂移）。 */
object BandAdapterDefaults {
    const val STATE_UNKNOWN = "unknown"
    const val STATE_INSTALLED = "installed"
    const val STATE_NOT_INSTALLED = "not_installed"
}
