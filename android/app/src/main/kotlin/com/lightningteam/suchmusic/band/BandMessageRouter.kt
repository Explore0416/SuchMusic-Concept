package com.lightningteam.suchmusic.band

import android.util.Log
import org.json.JSONObject

/**
 * 手环消息路由器（Kotlin 侧）。
 *
 * 职责（文档 §4.2）：
 * - **上行**：手环原始 JSON → 轻量校验信封 → 转发给 Dart（经 EventChannel）；
 * - **下行**：Dart 构造好的响应 / 事件 JSON → 经 [BandConnection] 发回手环；
 * - **传输层安全网**：正常流量已由 Dart 侧按 900B 分片，此处仅对异常超限消息
 *   兜底分片（用 [BandChunkCodec]），避免单帧过大被底层静默丢弃。
 *
 * 业务语义（握手、版本/能力协商、幂等去重、命令落地）全部在 Dart 侧完成，
 * 本类**不解析业务**，只做信道与信封级别的转发。
 */
class BandMessageRouter(
    private val connection: BandConnection,
    private val onToDart: (String) -> Unit,
) {

    companion object {
        private const val TAG = "BandMessageRouter"

        /** 超过该字节数即触发兜底分片（4 × 单包上限，正常不会命中）。 */
        private const val SAFETY_CHUNK_THRESHOLD = BandChunkCodec.CHUNK_MAX_BYTES * 4
    }

    /** 收到手环上行文本：轻量校验后转发给 Dart。 */
    fun onBandMessage(text: String) {
        if (!looksLikeEnvelope(text)) {
            Log.w(TAG, "丢弃非法信封（非 JSON 对象 / 缺少 type）")
            return
        }
        try {
            onToDart(text)
        } catch (e: Throwable) {
            Log.w(TAG, "转发 Dart 失败: ${e.message}")
        }
    }

    /** 下发一段 JSON 到手环；超限时兜底分片。 */
    fun send(json: String): Boolean {
        val bytes = json.toByteArray(Charsets.UTF_8)
        return if (bytes.size > SAFETY_CHUNK_THRESHOLD) {
            sendChunked(json)
        } else {
            connection.send(json)
        }
    }

    // ── 内部 ──────────────────────────────────────────────────

    /** 极简信封校验：可解析为 JSON 对象且含字符串 `type`。 */
    private fun looksLikeEnvelope(text: String): Boolean {
        if (text.isBlank() || text[0] != '{') return false
        return try {
            val obj = JSONObject(text)
            obj.optString("type").isNotEmpty()
        } catch (e: Throwable) {
            false
        }
    }

    /** 兜底分片：拆 header/data/end，逐帧包成 `evt xfer.chunk` 下发。 */
    private fun sendChunked(json: String): Boolean {
        return try {
            val tid = "t-srv-" + System.currentTimeMillis()
            val frames = BandChunkCodec.split(tid = tid, kind = "raw", fullJson = json)
            var ok = true
            for (frame in frames) {
                val envelope = "{\"v\":1,\"type\":\"evt\",\"event\":\"xfer.chunk\",\"payload\":$frame}"
                ok = connection.send(envelope) && ok
                if (!ok) break
            }
            ok
        } catch (e: Throwable) {
            Log.w(TAG, "sendChunked 失败: ${e.message}")
            false
        }
    }
}
