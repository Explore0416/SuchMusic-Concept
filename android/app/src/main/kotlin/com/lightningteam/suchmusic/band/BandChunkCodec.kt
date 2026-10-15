package com.lightningteam.suchmusic.band

import java.util.zip.CRC32

/**
 * 手环分片编解码（header → data → end 三段式，见 docs/ARCH-手环通信.md §3.8）。
 *
 * 约束（与文档一致）：
 * - 单包字节上限 [CHUNK_MAX_BYTES] = **900**（保守值，真实上限待真机验证 V2）；
 * - 手环组装缓存上限 [ASSEMBLE_MAX_BYTES] = **8192**（超限即 E_TOOLARGE）；
 * - 校验：整包 `crc32`（IEEE，与 zlib / `java.util.zip.CRC32` 同款；Dart 侧同款实现）；
 * - 分片内容二选一：文本走 `txt`（不额外 Base64，省 ~33% 带宽），二进制走 `b64`。
 *
 * 本类**仅依赖 JDK**（无 Android API、无第三方库），因此可在纯 JVM 下单元测试。
 *
 * 说明：协议级分片由 Dart 侧 `band_chunk.dart` 主导（它才是与手环协商的 RPC 实现），
 * 本类提供**同构的参考实现**，供 [BandMessageRouter] 作为传输层安全网使用
 * （正常流量已由 Dart 分片，此处仅兜底超限消息）。
 */
object BandChunkCodec {

    /** 单包字节上限（保守值）。 */
    const val CHUNK_MAX_BYTES = 900

    /** 组装缓存上限。 */
    const val ASSEMBLE_MAX_BYTES = 8192

    private const val B64_ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    /** IEEE CRC32，返回 0..0xFFFFFFFF（以 Long 承载无符号值）。 */
    fun crc32(bytes: ByteArray): Long {
        val crc = CRC32()
        crc.update(bytes)
        return crc.value
    }

    /** CRC32 的小写 8 位十六进制表示。 */
    fun crc32Hex(bytes: ByteArray): String =
        java.lang.String.format("%08x", crc32(bytes))

    /**
     * 把一整段文本拆成 header/data…/end 三类**分片载荷 JSON**（不含外层信封）。
     *
     * 按 UTF-8 字节数切分，**不切断多字节字符**（按码点聚合）。
     *
     * @param tid       传输 id（同一次分片唯一）
     * @param kind      载荷类型：`lyric_window` / `search_result` / `cover` / `raw`
     * @param fullJson  待分片的完整文本（通常是被序列化的 JSON 字符串）
     * @param meta      header 附带的元信息（可选）
     */
    fun split(
        tid: String,
        kind: String,
        fullJson: String,
        meta: Map<String, Any?> = emptyMap(),
    ): List<String> {
        val allBytes = fullJson.toByteArray(Charsets.UTF_8)
        val crcHex = crc32Hex(allBytes)

        val dataFrames = ArrayList<String>()
        val buf = StringBuilder()
        var bufBytes = 0
        var seq = 0
        var i = 0
        while (i < fullJson.length) {
            val cp = fullJson.codePointAt(i)
            val charCount = Character.charCount(cp)
            val chBytes = String(Character.toChars(cp)).toByteArray(Charsets.UTF_8).size
            if (bufBytes + chBytes > CHUNK_MAX_BYTES && buf.isNotEmpty()) {
                dataFrames.add(dataFrame(tid, seq++, buf.toString()))
                buf.setLength(0)
                bufBytes = 0
            }
            buf.appendCodePoint(cp)
            bufBytes += chBytes
            i += charCount
        }
        if (buf.isNotEmpty() || dataFrames.isEmpty()) {
            // 空文本也产出 1 个（空）data 分片，保证 total >= 1、组装语义稳定
            dataFrames.add(dataFrame(tid, seq++, buf.toString()))
        }

        val frames = ArrayList<String>(dataFrames.size + 2)
        frames.add(headerFrame(tid, kind, dataFrames.size, allBytes.size, crcHex, meta))
        frames.addAll(dataFrames)
        frames.add(endFrame(tid, dataFrames.size, crcHex))
        return frames
    }

    // ── Base64（纯 Kotlin 实现，避免依赖 android.util.Base64 / API 26 的 java.util.Base64）──

    fun encodeBase64(data: ByteArray): String {
        val sb = StringBuilder((data.size + 2) / 3 * 4)
        var i = 0
        while (i + 2 < data.size) {
            val n = ((data[i].toInt() and 0xFF) shl 16) or
                ((data[i + 1].toInt() and 0xFF) shl 8) or
                (data[i + 2].toInt() and 0xFF)
            sb.append(B64_ALPHABET[(n ushr 18) and 0x3F])
                .append(B64_ALPHABET[(n ushr 12) and 0x3F])
                .append(B64_ALPHABET[(n ushr 6) and 0x3F])
                .append(B64_ALPHABET[n and 0x3F])
            i += 3
        }
        val rem = data.size - i
        if (rem == 1) {
            val n = (data[i].toInt() and 0xFF) shl 16
            sb.append(B64_ALPHABET[(n ushr 18) and 0x3F])
                .append(B64_ALPHABET[(n ushr 12) and 0x3F])
                .append("==")
        } else if (rem == 2) {
            val n = ((data[i].toInt() and 0xFF) shl 16) or ((data[i + 1].toInt() and 0xFF) shl 8)
            sb.append(B64_ALPHABET[(n ushr 18) and 0x3F])
                .append(B64_ALPHABET[(n ushr 12) and 0x3F])
                .append(B64_ALPHABET[(n ushr 6) and 0x3F])
                .append("=")
        }
        return sb.toString()
    }

    fun decodeBase64(text: String): ByteArray {
        val clean = text.filter { !it.isWhitespace() }
        val out = java.io.ByteArrayOutputStream()
        var buffer = 0
        var bits = 0
        for (c in clean) {
            if (c == '=') break
            val idx = B64_ALPHABET.indexOf(c)
            if (idx < 0) continue
            buffer = (buffer shl 6) or idx
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.write((buffer ushr bits) and 0xFF)
            }
        }
        return out.toByteArray()
    }

    // ── 帧构造 ────────────────────────────────────────────────

    private fun headerFrame(
        tid: String,
        kind: String,
        total: Int,
        bytes: Int,
        crc: String,
        meta: Map<String, Any?>,
    ): String {
        val sb = StringBuilder()
        sb.append("{\"tid\":\"").append(jsonEscape(tid)).append("\"")
        sb.append(",\"phase\":\"header\"")
        sb.append(",\"kind\":\"").append(jsonEscape(kind)).append("\"")
        sb.append(",\"total\":").append(total)
        sb.append(",\"bytes\":").append(bytes)
        sb.append(",\"crc32\":\"").append(crc).append("\"")
        if (meta.isNotEmpty()) {
            sb.append(",\"meta\":{")
            var first = true
            for ((k, v) in meta) {
                if (!first) sb.append(',')
                first = false
                sb.append('"').append(jsonEscape(k)).append("\":")
                when (v) {
                    is Number, is Boolean -> sb.append(v.toString())
                    null -> sb.append("null")
                    else -> sb.append('"').append(jsonEscape(v.toString())).append('"')
                }
            }
            sb.append('}')
        }
        sb.append('}')
        return sb.toString()
    }

    private fun dataFrame(tid: String, seq: Int, text: String): String =
        "{\"tid\":\"${jsonEscape(tid)}\",\"phase\":\"data\",\"seq\":$seq,\"txt\":\"${jsonEscape(text)}\"}"

    private fun endFrame(tid: String, total: Int, crc: String): String =
        "{\"tid\":\"${jsonEscape(tid)}\",\"phase\":\"end\",\"total\":$total,\"crc32\":\"$crc\"}"

    private fun jsonEscape(s: String): String {
        val sb = StringBuilder(s.length + 8)
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> if (c < ' ') sb.append(java.lang.String.format("\\u%04x", c.code)) else sb.append(c)
            }
        }
        return sb.toString()
    }

    /**
     * 组装器：消费 [split] 产出的分片载荷 JSON，按 `seq` 归位，`end` 时校验
     * `count == total && crc32(buf) == crc32`。
     *
     * 校验失败时抛 [IllegalStateException]，`message` 形如
     * `E_TOOLARGE` 或 `E_CRC missing=[..]`，供上层决定是否发 `xfer.nack`。
     */
    class Assembler(private val maxBytes: Int = ASSEMBLE_MAX_BYTES) {

        private var total = -1
        private var expectedCrc: String? = null
        private val parts = sortedMapOf<Int, String>()
        private var overflow = false

        fun reset() {
            total = -1
            expectedCrc = null
            parts.clear()
            overflow = false
        }

        /** 消费一帧载荷 JSON。 */
        fun onFrame(frameJson: String) {
            when (extractString(frameJson, "phase")) {
                "header" -> {
                    total = extractInt(frameJson, "total") ?: -1
                    expectedCrc = extractString(frameJson, "crc32")
                    val bytes = extractInt(frameJson, "bytes") ?: 0
                    if (bytes > maxBytes) overflow = true
                    parts.clear()
                }
                "data" -> {
                    val seq = extractInt(frameJson, "seq") ?: return
                    val txt = extractString(frameJson, "txt") ?: ""
                    parts[seq] = txt
                    if (currentBytes() > maxBytes) overflow = true
                }
                "end" -> Unit
            }
        }

        fun isComplete(): Boolean {
            if (total < 0) return false
            for (i in 0 until total) if (!parts.containsKey(i)) return false
            return true
        }

        fun missingSeqs(): List<Int> {
            if (total <= 0) return emptyList()
            val miss = ArrayList<Int>()
            for (i in 0 until total) if (!parts.containsKey(i)) miss.add(i)
            return miss
        }

        /** 组装并校验；失败抛异常（消息含错误码）。 */
        fun assemble(): String {
            if (overflow) throw IllegalStateException("E_TOOLARGE")
            val miss = missingSeqs()
            if (miss.isNotEmpty()) throw IllegalStateException("E_CRC missing=$miss")
            val sb = StringBuilder()
            for (i in 0 until total) sb.append(parts[i])
            val text = sb.toString()
            val actual = crc32Hex(text.toByteArray(Charsets.UTF_8))
            if (expectedCrc != null && actual != expectedCrc) {
                throw IllegalStateException("E_CRC calc=$actual expect=$expectedCrc")
            }
            return text
        }

        private fun currentBytes(): Int {
            var n = 0
            for (v in parts.values) n += v.toByteArray(Charsets.UTF_8).size
            return n
        }
    }

    // ── 极简 JSON 字段抽取（仅用于解析本类自己产出的帧格式）────────

    private fun extractRawValue(json: String, key: String): String? {
        val token = "\"$key\":"
        var i = json.indexOf(token)
        if (i < 0) return null
        i += token.length
        while (i < json.length && json[i].isWhitespace()) i++
        if (i >= json.length) return null
        return if (json[i] == '"') {
            i++
            val sb = StringBuilder()
            loop@ while (i < json.length) {
                val c = json[i]
                when (c) {
                    '\\' -> {
                        i++
                        if (i >= json.length) break@loop
                        when (val e = json[i]) {
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'u' -> if (i + 4 < json.length) {
                                val hex = json.substring(i + 1, i + 5)
                                i += 4
                                sb.append(hex.toInt(16).toChar())
                            }
                            else -> sb.append(e)
                        }
                    }
                    '"' -> break@loop
                    else -> sb.append(c)
                }
                i++
            }
            sb.toString()
        } else {
            val start = i
            while (i < json.length && json[i] != ',' && json[i] != '}') i++
            json.substring(start, i).trim()
        }
    }

    private fun extractString(json: String, key: String): String? {
        val v = extractRawValue(json, key) ?: return null
        return if (v == "null") null else v
    }

    private fun extractInt(json: String, key: String): Int? =
        extractRawValue(json, key)?.toIntOrNull()
}
