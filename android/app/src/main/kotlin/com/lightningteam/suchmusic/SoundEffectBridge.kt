package com.lightningteam.suchmusic

import android.content.Context
import android.content.SharedPreferences
import android.media.audiofx.DynamicsProcessing
import android.os.Build
import android.util.Log

/**
 * 音效桥：用系统 `android.media.audiofx.DynamicsProcessing`（API 28+，无需高级权限）
 * 绑定音频会话 0（全局输出处理），按预设写入 11 段前级 EQ + 多频段压缩（MBC）+ Limiter。
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

    /** 当前 preset code（关闭时为 `PRESET_OFF`），内存优先、prefs 兜底 */
    private var currentCode: String = readStoredCode()

    /** DynamicsProcessing 是否可用（API 28+ 且系统实现存在） */
    fun available(): Boolean {
        return Build.VERSION.SDK_INT >= MIN_SDK
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
     * 未知 code 或系统不支持时返回 false。
     */
    fun apply(presetCode: String): Boolean {
        if (!available()) return false
        val preset = presets.firstOrNull { it.code == presetCode } ?: return false
        return try {
            releaseEffect()
            val built = DynamicsProcessing(
                0,
                0,
                DynamicsProcessing.Config.Builder(
                    DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION,
                    1, // 单声道配置：由 setAllChannelsTo 复制到全部实际声道
                    true, // preEq 启用（音效主体）
                    FREQUENCIES.size,
                    true, // mbc 启用（与 Limiter 协同防爆音）
                    FREQUENCIES.size,
                    false, // postEq 不启用，避免与 preEq 叠加导致削波
                    0,
                    true, // limiter 启用
                ).setPreferredFrameDuration(FRAME_DURATION_MS)
                    .setAllChannelsTo(buildChannel(preset.gains))
                    .build()
            )
            built.enabled = true
            effect = built
            currentCode = preset.code
            saveCode(preset.code)
            true
        } catch (e: Exception) {
            // 某些 ROM 不支持会话 0 的全局处理：静默降级，不抛给 Flutter
            Log.w(TAG, "apply failed: " + e.message)
            releaseEffectQuietly()
            false
        }
    }

    /** 关闭音效：释放实例并把状态标记为 off */
    fun disable(): Boolean {
        return try {
            releaseEffect()
            currentCode = PRESET_OFF
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

    /** 构建一个声道的完整配置：输入增益 + 前级 EQ + MBC + Limiter */
    private fun buildChannel(gains: FloatArray): DynamicsProcessing.Channel {
        // 构造签名：inputGain / preEqInUse+bandCount / mbcInUse+bandCount /
        // postEqInUse+bandCount / limiterInUse
        val channel = DynamicsProcessing.Channel(
            0f,
            true,
            FREQUENCIES.size,
            true,
            FREQUENCIES.size,
            false,
            0,
            true,
        )
        channel.setInputGain(0f)
        channel.setPreEq(buildPreEq(gains))
        channel.setMbc(buildMbc())
        channel.setLimiter(buildLimiter())
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
