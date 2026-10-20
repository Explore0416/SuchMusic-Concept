package com.lightningteam.suchmusic

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.media.audiofx.DynamicsProcessing
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * 音效桥：用系统 `android.media.audiofx.DynamicsProcessing`（API 28+，无需高级权限）。
 *
 * **绑定的是 App 自己播放音频的会话**（由 just_audio / ExoPlayer 通过
 * `AudioPlayer.androidAudioSessionId` 暴露，一路透传到本类）。
 * 按预设写入 11 段前级 EQ + 多频段压缩（MBC）+ Limiter。
 *
 * 历史 Bug（已修复）：早期实现把效果器挂在 **会话 0（全局输出混音）** 上。
 * AOSP 对会话 0 已有明确警告（`attaching a DynamicsProcessing to global output mix is
 * deprecated`），且小米 HyperOS 等现代 ROM 会直接拒绝第三方 App 挂全局混音——
 * `AudioEffect.native_setup` 返回 `ERROR_BAD_VALUE`，构造函数抛
 * `IllegalArgumentException("Effect type: ... not supported.")`；即便侥幸不抛，
 * 全局混音下 `getChannelCount()` 返回 0，随后 `Config(channelCount=0, ...)` 又会抛
 * `IllegalArgumentException("channel resizing less than 1 not allowed")`。
 * 两条路径都会走到 `catch` 并被静默吞掉，Dart 侧误报「当前设备暂不支持该音效」。
 *
 * 预设增益数组取自 HubeRSoundX 公开的 HxCore 曲线（README「关于算法 - HxCore」），
 * 仅做数值复用，不引入任何第三方依赖。
 *
 * 设计原则（与 IslandBridge 一致）：**尽力而为，任何失败静默降级**，
 * 所有对外方法都 try/catch 兜底并返回安全值，绝不把异常抛给 Flutter。
 */
class SoundEffectBridge(private val context: Context) {

    companion object {
        private const val TAG = "SoundEffectBridge"

        /** Dart 侧 `SoundEffectService` 使用的通道名，两侧必须一致 */
        const val CHANNEL = "com.lightningteam.suchmusic/soundfx"

        /** DynamicsProcessing 最低支持版本（Android 9 / API 28） */
        private const val MIN_SDK = 28

        /** 当前音效持久化 key（与 `sound_effect_preset` 约定一致） */
        private const val PREFS_NAME = "such_music_soundfx"
        private const val KEY_PRESET = "sound_effect_preset"

        /** 关闭音效时写入的标记值 */
        private const val PRESET_OFF = "off"

        /** 系统音量变化广播（AOSP 内部常量，字符串稳定可用） */
        private const val VOLUME_CHANGED_ACTION = "android.media.VOLUME_CHANGED_ACTION"

        /** 能力探测失败结果的缓存时长（毫秒），过期后重新探测 */
        private const val AVAILABLE_FAIL_TTL_MS = 30_000L

        /** 处理帧长（毫秒），取 HxCore 常用的 10ms */
        private const val FRAME_DURATION_MS = 10f

        /** 频响曲线频点（对数分布 25Hz ~ 16kHz），共 11 段，与预设数组长度一一对应 */
        private val FREQUENCIES = floatArrayOf(
            25f, 40f, 63f, 100f, 160f, 250f, 400f, 630f,
            1000f, 4000f, 16000f
        )

        /** Limiter 默认参数（README：attack=1 / release=60 / ratio=10 / threshold=-2 / postGain=0） */
        private const val LIMITER_ATTACK_TIME = 1f
        private const val LIMITER_RELEASE_TIME = 60f
        private const val LIMITER_RATIO = 10f
        private const val LIMITER_THRESHOLD = -2f
        private const val LIMITER_POST_GAIN = 0f

        /** MbcBand 中不易从上下文推断的固定参数，集中在此便于核对 */
        private const val MBC_ATTACK_TIME = 1f
        private const val MBC_RELEASE_TIME = 60f
        private const val MBC_RATIO = 2f
        private const val MBC_THRESHOLD = -2f
        private const val MBC_KNEE_WIDTH = 3.5f
        private const val MBC_NOISE_GATE = -90f
        private const val MBC_EXPANDER_RATIO = 2f
        private const val MBC_PRE_GAIN = 0f
        private const val MBC_POST_GAIN = 0f
    }

    /** 预设：code + 展示名 + 说明 + 11 段增益（dB） */
    private data class Preset(
        val code: String,
        val name: String,
        val desc: String,
        val gains: FloatArray,
    )

    /**
     * 单个降级策略：决定 Config / Channel 使用哪种 variant，以及是否启用 MBC / Limiter。
     * 前级 EQ 始终启用（音效主体）；postEq 始终关闭（避免与 preEq 叠加削波）。
     */
    private data class Strategy(
        val name: String,
        val variant: Int,
        val withMbc: Boolean,
        val withLimiter: Boolean,
    )

    private val presets: List<Preset> = listOf(
        Preset("default", "默认", "不做任何增益，保持原声", floatArrayOf(0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f)),
        Preset("origin_voice", "原声人声", "突出人声与齿音，适合流行 / 人声", floatArrayOf(4f, 1.5f, -0.44f, 0.7f, 2f, -4.5f, 0.2f, 1.7f, 3f, 0.8f, 0f)),
        Preset("jbl_flip", "JBL Flip", "推动低频动态，适合蓝牙小音箱", floatArrayOf(0f, 0f, 10f, 7f, 1.2f, 0f, -2f, -2.5f, 0f, 0f, 0f)),
        Preset("jbl_partybox", "JBL PartyBox", "强低频氛围，适合派对音箱", floatArrayOf(0f, 9f, 3.6f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f)),
        Preset("n12t_origin", "N12T 原声", "强低频 + 收敛中高频，厚重风格", floatArrayOf(9f, -1f, -6.6f, -4f, 8.5f, -7.7f, -2.35f, -6f, 1f, 1f, 1f)),
        Preset("hxcore_surround", "HxCore 环绕", "左右声道差异化曲线，声场更宽", floatArrayOf(0f, 6f, 3f, 0f, 5f, 2f, 5f, 3f, 0f, 0f, 0f)),
    )

    /** 当前生效的 DynamicsProcessing 实例（未启用时为 null） */
    private var effect: DynamicsProcessing? = null

    /** 当前已生效的 preset code（关闭时为 `PRESET_OFF`），内存优先、prefs 兜底 */
    private var currentCode: String = readStoredCode()

    /** 用户**期望**的 preset code（即使本次 apply 失败也会记住，待会话就绪后重试） */
    private var desiredCode: String = readStoredCode()

    /** 当前绑定的真实音频会话 ID；0 表示尚未取得 / 回退全局混音 */
    private var currentSessionId: Int = 0

    /** 是否已成功应用过某预设（诊断用） */
    private var success: Boolean = false

    /** 最近一次失败原因（诊断用，null 表示无错误） */
    private var lastError: String? = null

    /** 最近一次成功 / 失败的策略名（诊断用） */
    private var lastStrategy: String? = null

    /** 可用性探测结果缓存（null 表示尚未确定） */
    private var availableCache: Boolean? = null

    /** 缓存写入时间：**失败**只缓存一小段时间，避免一次失败永久禁用入口 */
    private var availableCacheAt: Long = 0L

    /** 音量变化监听（系统调音量会让部分 ROM 重置 AudioEffect，导致音效"消失"） */
    private var volumeReceiver: BroadcastReceiver? = null

    /** 音量连按时防抖，只重建一次 */
    private var pendingReapply: Runnable? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * DynamicsProcessing 是否可用。
     *
     * 真实探测（而非仅判断 SDK 版本）：尝试用当前音频会话创建一次最简效果器后立即 release，
     * 结果缓存。**尚无播放会话时乐观返回 true**，避免播放前就把预设误判为「不支持」而隐藏；
     * 真实会话就绪后 [setSessionId] 会重新探测并写入缓存。
     *
     * **仅用于 UI 能力展示，不作为 [apply] 的门禁**：[apply] 唯一合法的硬门禁是系统版本
     * （SDK >= [MIN_SDK]）；本方法的结果不允许短路降级策略链。
     */
    fun available(): Boolean {
        if (Build.VERSION.SDK_INT < MIN_SDK) {
            availableCache = false
            return false
        }
        // 成功结果可以长期复用；**失败结果只缓存 30 秒**。
        // 否则一次探测失败（如会话切换瞬间）会让入口永久显示「不可用」，
        // 用户表现为「音效没了、而且再也设置不了」。
        if (availableCache == true) return true
        if (availableCache == false &&
            SystemClock.elapsedRealtime() - availableCacheAt < AVAILABLE_FAIL_TTL_MS
        ) {
            return false
        }

        val session = if (currentSessionId > 0) currentSessionId else 0
        if (session <= 0) {
            // 无可探测的真实会话：乐观放行，交由后续真实 apply 决定
            return true
        }
        val ok = probe(session)
        availableCache = ok
        availableCacheAt = SystemClock.elapsedRealtime()
        return ok
    }

    /**
     * 预设列表：每项含 `code` / `name` / `desc`。
     * 通过 MethodChannel 传输时会被自动转成 `List<Map<String, Any?>>`。
     */
    fun listPresets(): List<Map<String, Any?>> {
        return presets.map {
            mapOf(
                "code" to it.code,
                "name" to it.name,
                "desc" to it.desc,
            )
        }
    }

    /**
     * 应用预设：先释放旧实例，再按增益数组构建 EQ + MBC + Limiter 并置为 enabled。
     *
     * **前置门禁**：仅系统版本（SDK >= [MIN_SDK]）。**不以 [available] 缓存作硬门禁**——
     * 否则一旦探测曾失败过一次，[availableCache] 被永久置为 false，之后任何预设都会
     * 在此短路返回 false，整条降级策略链（含 6 级兜底）都不会执行。会话变更与缓存失效
     * 会被提到最前（SDK 判定之后、任何探测之前），确保换会话后直接调用本方法也不会被
     * 上一个会话的陈旧探测结果短路。
     *
     * @param presetCode 预设 code（未知 code 返回 false）。
     * @param sessionId  播放音频会话 ID（来自 just_audio）。**优先使用真实会话**；
     *                   仅当 [sessionId] <= 0 且尚无已记录会话时才回退到 0（保留兜底）。
     *
     * 降级策略链：逐级尝试、每级独立 try/catch，全部失败才返回 false：
     * 1. preEq + MBC + Limiter（11 段）
     * 2. 仅 preEq + Limiter（去掉 MBC）
     * 3. 仅 preEq
     * 4. 以上三级再用 `VARIANT_FAVOR_TIME_RESOLUTION` 重试一遍。
     */
    fun apply(presetCode: String, sessionId: Int): Boolean {
        // 唯一合法的前置门禁：系统版本。不得以 availableCache 短路，否则降级链失效。
        if (Build.VERSION.SDK_INT < MIN_SDK) return false

        // 会话更新与缓存失效提到最前（SDK 判定之后、任何探测之前）：
        // 即便换会话后直接以新会话调用 apply（未经 setSessionId），
        // 也不会被上一个会话的陈旧探测结果短路。
        if (sessionId > 0 && sessionId != currentSessionId) {
            currentSessionId = sessionId
            availableCache = null
        }

        val preset = presets.firstOrNull { it.code == presetCode } ?: return false

        // 先记住用户期望的预设：即使本次全部策略失败，也会在会话就绪 / 下次启动时重试
        desiredCode = preset.code
        saveCode(preset.code)

        // 优先真实播放会话；仅当完全没有会话时回退到 0（保留兜底，避免直接不可用）
        val effectiveSession = when {
            sessionId > 0 -> sessionId
            currentSessionId > 0 -> currentSessionId
            else -> 0
        }

        // 释放旧实例，避免实例泄漏与状态残留
        releaseEffect()

        for (strategy in buildStrategies()) {
            val built = try {
                DynamicsProcessing(
                    0,
                    effectiveSession,
                    DynamicsProcessing.Config.Builder(
                        strategy.variant,
                        1, // 单声道配置：由 setAllChannelsTo 复制到全部实际声道
                        true, // preEq 始终启用（音效主体）
                        FREQUENCIES.size,
                        strategy.withMbc,
                        if (strategy.withMbc) FREQUENCIES.size else 0,
                        false, // postEq 不启用，避免与 preEq 叠加导致削波
                        0,
                        strategy.withLimiter,
                    ).setPreferredFrameDuration(FRAME_DURATION_MS)
                        .setAllChannelsTo(buildChannel(preset.gains, strategy))
                        .build()
                )
            } catch (e: Exception) {
                lastError = e.message
                lastStrategy = strategy.name + " (build)"
                Log.w(TAG, "apply strategy [${strategy.name}] build failed: " + e.message)
                continue
            }

            // 构建成功后再置为 enabled（此步单独 try/catch，失败则释放并试下一级）
            try {
                built.enabled = true
                effect = built
                currentCode = preset.code
                success = true
                lastStrategy = strategy.name
                lastError = null
                availableCache = true
                availableCacheAt = SystemClock.elapsedRealtime()
                ensureVolumeWatcher()
                return true
            } catch (e: Exception) {
                lastError = e.message
                lastStrategy = strategy.name + " (enable)"
                Log.w(TAG, "apply strategy [${strategy.name}] enable failed: " + e.message)
                try {
                    built.release()
                } catch (_: Exception) {
                }
            }
        }

        success = false
        if (lastError == null) lastError = "all strategies failed"
        if (lastStrategy == null) lastStrategy = "none"
        Log.w(TAG, "apply failed after all strategies; session=$effectiveSession lastError=$lastError")
        return false
    }

    /**
     * 会话变化时更新音频会话 ID：若存在期望的预设，则用新会话重新 apply；
     * 否则仅记录会话。会话变化会重置可用性探测缓存，让 [available] 用真实会话重新探测。
     *
     * @return true 表示处理成功（含「仅记录会话、无待应用预设」的情形）。
     */
    fun setSessionId(id: Int): Boolean {
        if (id <= 0) return false
        val changed = id != currentSessionId
        currentSessionId = id
        if (changed) availableCache = null

        val desired = desiredCode
        if (desired.isEmpty() || desired == PRESET_OFF) {
            // 未选择任何音效：仅记录会话，无需操作
            return true
        }
        return apply(desired, id)
    }

    /** 关闭音效：释放实例并把状态标记为 off */
    fun disable(): Boolean {
        return try {
            releaseEffect()
            currentCode = PRESET_OFF
            desiredCode = PRESET_OFF
            success = false
            saveCode(PRESET_OFF)
            true
        } catch (e: Exception) {
            Log.w(TAG, "disable failed: " + e.message)
            false
        }
    }

    /** 当前 preset code；未启用任何音效时返回 "off" */
    fun current(): String {
        return currentCode
    }

    /**
     * 监听系统音量变化。
     *
     * 部分 ROM（小米 HyperOS 等）在按音量键时会重建音频输出链路，
     * 已绑定的 `DynamicsProcessing` 被系统静默 detach —— 表现就是「调一下音量，
     * 音效突然没了」，而且实例引用还在、`enabled` 仍是 true，后续不会再重建。
     *
     * 这里在音量变化后 250ms（防连按）用当前会话重建一次效果器。
     * 广播是系统内部广播，只需动态注册，不需要任何权限。
     */
    private fun ensureVolumeWatcher() {
        if (volumeReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action == VOLUME_CHANGED_ACTION) scheduleReapply()
            }
        }
        try {
            val filter = IntentFilter(VOLUME_CHANGED_ACTION)
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(receiver, filter)
            }
            volumeReceiver = receiver
        } catch (e: Exception) {
            Log.w(TAG, "register volume receiver failed: " + e.message)
        }
    }

    /** 音量变化后防抖重建（只重建用户当前选择的预设） */
    private fun scheduleReapply() {
        val desired = desiredCode
        if (desired.isEmpty() || desired == PRESET_OFF) return
        pendingReapply?.let { mainHandler.removeCallbacks(it) }
        val run = Runnable {
            pendingReapply = null
            val code = desiredCode
            if (code.isEmpty() || code == PRESET_OFF) return@Runnable
            val ok = apply(code, currentSessionId)
            Log.i(TAG, "volume changed -> reapply $code ok=$ok session=$currentSessionId")
        }
        pendingReapply = run
        mainHandler.postDelayed(run, 250)
    }

    /** 释放监听（进程结束时由系统回收，这里只供显式清理） */
    fun releaseWatcher() {
        pendingReapply?.let { mainHandler.removeCallbacks(it) }
        pendingReapply = null
        volumeReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        volumeReceiver = null
    }

    /**
     * 诊断信息：供真机定位音效问题。
     * 返回 `sdkInt` / `deviceModel` / `success` / `lastError` / `lastStrategy` /
     * `currentCode` / `desiredCode` / `sessionId` / `enabled`。
     */
    fun diagnose(): Map<String, Any?> {
        val enabledState = try {
            effect?.enabled == true
        } catch (_: Exception) {
            false
        }
        return mapOf(
            "sdkInt" to Build.VERSION.SDK_INT,
            "deviceModel" to (Build.MANUFACTURER + " " + Build.MODEL),
            "success" to success,
            "lastError" to lastError,
            "lastStrategy" to lastStrategy,
            "currentCode" to currentCode,
            "desiredCode" to desiredCode,
            "sessionId" to currentSessionId,
            "enabled" to enabledState,
        )
    }

    /** 降级策略链：3 种配置 × 2 种 variant = 6 级尝试 */
    private fun buildStrategies(): List<Strategy> = listOf(
        Strategy("freq:preEq+mbc+limiter", DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, true, true),
        Strategy("freq:preEq+limiter", DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, false, true),
        Strategy("freq:preEq", DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, false, false),
        Strategy("time:preEq+mbc+limiter", DynamicsProcessing.VARIANT_FAVOR_TIME_RESOLUTION, true, true),
        Strategy("time:preEq+limiter", DynamicsProcessing.VARIANT_FAVOR_TIME_RESOLUTION, false, true),
        Strategy("time:preEq", DynamicsProcessing.VARIANT_FAVOR_TIME_RESOLUTION, false, false),
    )

    /** 真实可用性探测：用给定会话创建一次最简效果器后立即 release。 */
    private fun probe(sessionId: Int): Boolean {
        return try {
            val dp = DynamicsProcessing(
                0,
                sessionId,
                DynamicsProcessing.Config.Builder(
                    DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
                    1,
                    true,
                    FREQUENCIES.size,
                    false,
                    0,
                    false,
                    0,
                    false,
                ).build()
            )
            try {
                dp.release()
            } catch (e: Exception) {
                Log.w(TAG, "probe release failed: " + e.message)
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "probe failed: " + e.message)
            false
        }
    }

    /** 构建一个声道的完整配置：输入增益 + 前级 EQ（+ 可选 MBC / Limiter），按策略开关。 */
    private fun buildChannel(gains: FloatArray, strategy: Strategy): DynamicsProcessing.Channel {
        // 构造签名：inputGain / preEqInUse+bandCount / mbcInUse+bandCount /
        // postEqInUse+bandCount / limiterInUse
        val channel = DynamicsProcessing.Channel(
            0f,
            true,
            FREQUENCIES.size,
            strategy.withMbc,
            if (strategy.withMbc) FREQUENCIES.size else 0,
            false,
            0,
            strategy.withLimiter,
        )
        channel.setInputGain(0f)
        channel.setPreEq(buildPreEq(gains))
        if (strategy.withMbc) channel.setMbc(buildMbc())
        if (strategy.withLimiter) channel.setLimiter(buildLimiter())
        return channel
    }

    /** 按预设增益构建前级 EQ（11 段） */
    private fun buildPreEq(gains: FloatArray): DynamicsProcessing.Eq {
        val eq = DynamicsProcessing.Eq(true, true, FREQUENCIES.size)
        val count = minOf(FREQUENCIES.size, gains.size)
        for (i in 0 until count) {
            eq.setBand(i, DynamicsProcessing.EqBand(true, FREQUENCIES[i], gains[i]))
        }
        return eq
    }

    /**
     * 构建多频段压缩：与 Limiter 协同，抑制过高的低频电流声并防止爆音。
     * 逐段用 setter 显式赋值，避免依赖构造参数顺序（各版本实现不一致）。
     */
    private fun buildMbc(): DynamicsProcessing.Mbc {
        val mbc = DynamicsProcessing.Mbc(true, true, FREQUENCIES.size)
        for (i in FREQUENCIES.indices) {
            val band = DynamicsProcessing.MbcBand(
                true,
                FREQUENCIES[i],
                MBC_ATTACK_TIME,
                MBC_RELEASE_TIME,
                MBC_RATIO,
                MBC_THRESHOLD,
                MBC_KNEE_WIDTH,
                MBC_NOISE_GATE,
                MBC_EXPANDER_RATIO,
                MBC_PRE_GAIN,
                MBC_POST_GAIN,
            )
            mbc.setBand(i, band)
        }
        return mbc
    }

    /** 构建 Limiter：参数与 HxCore 默认值一致 */
    private fun buildLimiter(): DynamicsProcessing.Limiter {
        // 先构造再逐个赋值：不依赖构造参数顺序，避免不同系统实现下的错位
        val limiter = DynamicsProcessing.Limiter(
            true,
            true,
            0,
            LIMITER_ATTACK_TIME,
            LIMITER_RELEASE_TIME,
            LIMITER_RATIO,
            LIMITER_THRESHOLD,
            LIMITER_POST_GAIN,
        )
        limiter.setLinkGroup(0)
        limiter.setAttackTime(LIMITER_ATTACK_TIME)
        limiter.setReleaseTime(LIMITER_RELEASE_TIME)
        limiter.setRatio(LIMITER_RATIO)
        limiter.setThreshold(LIMITER_THRESHOLD)
        limiter.setPostGain(LIMITER_POST_GAIN)
        return limiter
    }

    /** 释放当前实例（异常静默） */
    private fun releaseEffect() {
        try {
            effect?.enabled = false
        } catch (e: Exception) {
            Log.w(TAG, "disable effect failed: " + e.message)
        }
        releaseEffectQuietly()
    }

    private fun releaseEffectQuietly() {
        try {
            effect?.release()
        } catch (e: Exception) {
            Log.w(TAG, "release effect failed: " + e.message)
        }
        effect = null
    }

    private fun prefs(): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun readStoredCode(): String {
        return try {
            prefs().getString(KEY_PRESET, PRESET_OFF) ?: PRESET_OFF
        } catch (e: Exception) {
            PRESET_OFF
        }
    }

    private fun saveCode(code: String) {
        try {
            prefs().edit().putString(KEY_PRESET, code).apply()
        } catch (e: Exception) {
            Log.w(TAG, "save preset failed: " + e.message)
        }
    }
}
